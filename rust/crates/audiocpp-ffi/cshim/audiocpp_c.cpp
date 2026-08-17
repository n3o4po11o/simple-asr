// simple-asr: audio.cpp C ABI shim 实现。
// 对照 CLI 用法（app/cli/main.cpp）：Registry → load(ModelLoadRequest) →
// create_task_session(TaskSpec, SessionOptions) → IOfflineVoiceTaskSession::run。

#include "audiocpp_c.h"

#include "engine/framework/core/backend.h"
#include "engine/framework/runtime/model.h"
#include "engine/framework/runtime/registry.h"
#include "engine/framework/runtime/session.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>

namespace {

thread_local std::string g_last_error;

using ModelHandle = std::unique_ptr<engine::runtime::ILoadedVoiceModel>;

engine::core::BackendType parse_backend(const char *value) {
    const std::string v = value ? value : "cpu";
    if (v == "cuda") return engine::core::BackendType::Cuda;
    if (v == "hip" || v == "rocm") return engine::core::BackendType::Hip;
    if (v == "vulkan") return engine::core::BackendType::Vulkan;
    if (v == "metal") return engine::core::BackendType::Metal;
    return engine::core::BackendType::Cpu;
}

engine::runtime::ModelRegistry &registry() {
    // 默认构造的 ModelRegistry 无 loader；make_default_registry 注册全部内置族
    static engine::runtime::ModelRegistry instance =
        engine::runtime::make_default_registry();
    return instance;
}

} // namespace

extern "C" {

const char *acpp_last_error(void) { return g_last_error.c_str(); }

/* 调试用：逗号分隔的已注册模型族 */
const char *acpp_families(void) {
    static std::string cached;
    if (cached.empty()) {
        for (const auto &f : registry().families()) {
            if (!cached.empty()) cached += ",";
            cached += f;
        }
    }
    return cached.c_str();
}

void *acpp_model_load(const char *model_path, const char *family_hint) {
    try {
        engine::runtime::ModelLoadRequest request;
        request.model_path = model_path;
        if (family_hint != nullptr && *family_hint != '\0') {
            request.family_hint = family_hint;
        }
        return new ModelHandle(registry().load(request));
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return nullptr;
    } catch (...) {
        g_last_error = "unknown error in acpp_model_load";
        return nullptr;
    }
}

void acpp_model_free(void *model) {
    delete static_cast<ModelHandle *>(model);
}

int acpp_transcribe(void *model,
                    const float *samples,
                    size_t sample_count,
                    const char *backend,
                    int device,
                    int threads,
                    const char *language,
                    char **out_text,
                    char **out_lang) {
    try {
        auto &handle = *static_cast<ModelHandle *>(model);
        if (!handle) {
            g_last_error = "null model handle";
            return -1;
        }

        engine::runtime::TaskSpec spec;
        spec.task = engine::runtime::VoiceTaskKind::Asr;
        spec.mode = engine::runtime::RunMode::Offline;

        engine::runtime::SessionOptions session_options;
        session_options.backend.type = parse_backend(backend);
        session_options.backend.device = device;
        session_options.backend.threads = threads > 0 ? threads : 4;

        auto session = handle->create_task_session(spec, session_options);
        auto *offline =
            dynamic_cast<engine::runtime::IOfflineVoiceTaskSession *>(session.get());
        if (offline == nullptr) {
            g_last_error = "task session does not support offline execution";
            return -1;
        }

        engine::runtime::TaskRequest request;
        engine::runtime::AudioBuffer audio;
        audio.sample_rate = 16000;
        audio.channels = 1;
        audio.samples.assign(samples, samples + sample_count);
        request.audio_input = std::move(audio);
        if (language != nullptr && *language != '\0') {
            request.options["language"] = language;
        }

        // run 前必须 prepare（与 CLI 一致：build_preparation_request(request)）
        offline->prepare(engine::runtime::build_preparation_request(request));
        const auto result = offline->run(request);
        if (!result.text_output.has_value()) {
            g_last_error = "no text output";
            return -1;
        }
        *out_text = strdup(result.text_output->text.c_str());
        *out_lang = strdup(result.text_output->language.c_str());
        return 0;
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return -1;
    } catch (...) {
        g_last_error = "unknown error in acpp_transcribe";
        return -1;
    }
}

void acpp_free_string(char *s) { free(s); }


// ── 流式转写 ─────────────────────────────────────────────────────────────────


} // extern "C"
namespace {

using StreamHandle = std::unique_ptr<engine::runtime::IVoiceTaskSession>;

engine::core::BackendType parse_backend(const char *value);

} // namespace

extern "C" {

void *acpp_stream_start(void *model,
                        const char *backend,
                        int device,
                        int threads,
                        const char *language,
                        double chunk_seconds,
                        long long total_samples) {
    try {
        auto &handle = *static_cast<ModelHandle *>(model);
        if (!handle) {
            g_last_error = "null model handle";
            return nullptr;
        }
        engine::runtime::TaskSpec spec;
        spec.task = engine::runtime::VoiceTaskKind::Asr;
        spec.mode = engine::runtime::RunMode::Streaming;

        engine::runtime::SessionOptions session_options;
        session_options.backend.type = parse_backend(backend);
        session_options.backend.device = device;
        session_options.backend.threads = threads > 0 ? threads : 4;

        auto session = handle->create_task_session(spec, session_options);
        auto *streaming =
            dynamic_cast<engine::runtime::IStreamingVoiceTaskSession *>(session.get());
        if (streaming == nullptr) {
            g_last_error = "task session does not support streaming";
            return nullptr;
        }

        engine::runtime::TaskRequest request;
        if (language != nullptr && *language != '\0') {
            request.options["language"] = language;
        }
        if (chunk_seconds > 0.0) {
            request.options["audio_chunk_seconds"] = std::to_string(chunk_seconds);
        }
        // start_stream 前必须 prepare，且需要显式音频契约（容量按预期总长）
        engine::runtime::SessionPreparationRequest prep;
        prep.audio = engine::runtime::AudioPreparationContract{
            16000, 1, static_cast<int64_t>(total_samples)};
        streaming->prepare(prep);
        streaming->start_stream(request);
        return new StreamHandle(std::move(session));
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return nullptr;
    } catch (...) {
        g_last_error = "unknown error in acpp_stream_start";
        return nullptr;
    }
}

int acpp_stream_push(void *stream,
                     const float *samples,
                     size_t sample_count,
                     char **out_text,
                     int *has_text,
                     int *is_final) {
    try {
        auto &handle = *static_cast<StreamHandle *>(stream);
        auto *streaming =
            dynamic_cast<engine::runtime::IStreamingVoiceTaskSession *>(handle.get());
        if (streaming == nullptr) {
            g_last_error = "invalid stream handle";
            return -1;
        }
        engine::runtime::AudioChunk chunk;
        chunk.sample_rate = 16000;
        chunk.channels = 1;
        chunk.samples.assign(samples, samples + sample_count);
        const auto event = streaming->process_audio_chunk(chunk);

        *has_text = 0;
        *is_final = event.is_final ? 1 : 0;
        *out_text = nullptr;
        if (event.partial_text.has_value() && !event.partial_text->text.empty()) {
            *out_text = strdup(event.partial_text->text.c_str());
            *has_text = 1;
        }
        return 0;
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return -1;
    } catch (...) {
        g_last_error = "unknown error in acpp_stream_push";
        return -1;
    }
}

int acpp_stream_finish(void *stream, char **out_text, char **out_lang) {
    try {
        auto &handle = *static_cast<StreamHandle *>(stream);
        auto *streaming =
            dynamic_cast<engine::runtime::IStreamingVoiceTaskSession *>(handle.get());
        if (streaming == nullptr) {
            g_last_error = "invalid stream handle";
            return -1;
        }
        const auto result = streaming->finish_stream();
        if (!result.text_output.has_value()) {
            g_last_error = "no text output";
            return -1;
        }
        *out_text = strdup(result.text_output->text.c_str());
        *out_lang = strdup(result.text_output->language.c_str());
        return 0;
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return -1;
    } catch (...) {
        g_last_error = "unknown error in acpp_stream_finish";
        return -1;
    }
}

void acpp_stream_free(void *stream) {
    delete static_cast<StreamHandle *>(stream);
}

} // extern "C"

// ── 说话人分离 ───────────────────────────────────────────────────────────────

namespace {

// Sortformer 固定推理窗口（session.cpp kDefaultSessionLenSec；留 0.5s 余量
// 防边界截断报容量错）
constexpr double kDiarWindowSec = 19.5;

std::string merge_turns_json(const std::vector<engine::runtime::SpeakerTurn> & turns) {
    std::string out = "[";
    bool first = true;
    for (const auto &t : turns) {
        if (!first) out += ",";
        first = false;
        const double s = static_cast<double>(t.span.start_sample) / 16000.0;
        const double e = static_cast<double>(t.span.end_sample) / 16000.0;
        out += "{\"start_sec\":" + std::to_string(s) + ",\"end_sec\":" + std::to_string(e)
            + ",\"speaker\":\"" + t.speaker_id + "\"}";
    }
    out += "]";
    return out;
}

} // namespace

extern "C" {

int acpp_diarize(void *model,
                 const float *samples,
                 size_t sample_count,
                 const char *backend,
                 int device,
                 int threads,
                 char **out_json) {
    try {
        auto &handle = *static_cast<ModelHandle *>(model);
        if (!handle) {
            g_last_error = "null model handle";
            return -1;
        }
        engine::runtime::TaskSpec spec;
        spec.task = engine::runtime::VoiceTaskKind::Diarization;
        spec.mode = engine::runtime::RunMode::Offline;

        engine::runtime::SessionOptions session_options;
        session_options.backend.type = parse_backend(backend);
        session_options.backend.device = device;
        session_options.backend.threads = threads > 0 ? threads : 4;

        const size_t window = static_cast<size_t>(kDiarWindowSec * 16000.0);
        std::vector<engine::runtime::SpeakerTurn> merged;
        for (size_t off = 0; off < sample_count; off += window) {
            const size_t n = std::min(window, sample_count - off);
            auto session = handle->create_task_session(spec, session_options);
            auto *offline =
                dynamic_cast<engine::runtime::IOfflineVoiceTaskSession *>(session.get());
            if (offline == nullptr) {
                g_last_error = "diar session does not support offline execution";
                return -1;
            }
            engine::runtime::TaskRequest request;
            engine::runtime::AudioBuffer audio;
            audio.sample_rate = 16000;
            audio.channels = 1;
            audio.samples.assign(samples + off, samples + off + n);
            request.audio_input = std::move(audio);
            offline->prepare(engine::runtime::build_preparation_request(request));
            const auto result = offline->run(request);

            const int64_t base = static_cast<int64_t>(off);
            for (const auto &t : result.speaker_turns) {
                engine::runtime::SpeakerTurn shifted = t;
                shifted.span.start_sample += base;
                shifted.span.end_sample += base;
                // 相邻同说话人段直接衔接（跨窗断开或模型内部分段）
                if (!merged.empty()
                    && merged.back().speaker_id == shifted.speaker_id
                    && shifted.span.start_sample - merged.back().span.end_sample
                           <= static_cast<int64_t>(0.7 * 16000)) {
                    merged.back().span.end_sample =
                        std::max(merged.back().span.end_sample, shifted.span.end_sample);
                } else {
                    merged.push_back(shifted);
                }
            }
        }
        *out_json = strdup(merge_turns_json(merged).c_str());
        return 0;
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return -1;
    } catch (...) {
        g_last_error = "unknown error in acpp_diarize";
        return -1;
    }
}

} // extern "C"

// ── 词级强制对齐 ─────────────────────────────────────────────────────────────

namespace {

std::string words_to_json(const std::vector<engine::runtime::WordTimestamp> & words) {
    std::string out = "[";
    bool first = true;
    for (const auto &w : words) {
        if (!first) out += ",";
        first = false;
        const double s = static_cast<double>(w.span.start_sample) / 16000.0;
        const double e = static_cast<double>(w.span.end_sample) / 16000.0;
        // 词文本为 JSON 安全做最小转义
        std::string escaped;
        for (const char c : w.word) {
            if (c == '"' || c == '\\') escaped += '\\';
            escaped += c;
        }
        out += "{\"start_sec\":" + std::to_string(s) + ",\"end_sec\":" + std::to_string(e)
            + ",\"word\":\"" + escaped + "\",\"confidence\":" + std::to_string(w.confidence)
            + "}";
    }
    out += "]";
    return out;
}

} // namespace

extern "C" {

int acpp_align(void *model,
               const float *samples,
               size_t sample_count,
               const char *text,
               const char *language,
               const char *backend,
               int device,
               int threads,
               char **out_json) {
    try {
        auto &handle = *static_cast<ModelHandle *>(model);
        if (!handle) {
            g_last_error = "null model handle";
            return -1;
        }
        engine::runtime::TaskSpec spec;
        spec.task = engine::runtime::VoiceTaskKind::Alignment;
        spec.mode = engine::runtime::RunMode::Offline;

        engine::runtime::SessionOptions session_options;
        session_options.backend.type = parse_backend(backend);
        session_options.backend.device = device;
        session_options.backend.threads = threads > 0 ? threads : 4;

        auto session = handle->create_task_session(spec, session_options);
        auto *offline =
            dynamic_cast<engine::runtime::IOfflineVoiceTaskSession *>(session.get());
        if (offline == nullptr) {
            g_last_error = "align session does not support offline execution";
            return -1;
        }

        engine::runtime::TaskRequest request;
        engine::runtime::AudioBuffer audio;
        audio.sample_rate = 16000;
        audio.channels = 1;
        audio.samples.assign(samples, samples + sample_count);
        request.audio_input = std::move(audio);
        request.text_input = engine::runtime::Transcript{text ? text : "", language ? language : ""};

        offline->prepare(engine::runtime::build_preparation_request(request));
        const auto result = offline->run(request);
        *out_json = strdup(words_to_json(result.word_timestamps).c_str());
        return 0;
    } catch (const std::exception &e) {
        g_last_error = e.what();
        return -1;
    } catch (...) {
        g_last_error = "unknown error in acpp_align";
        return -1;
    }
}

} // extern "C"
