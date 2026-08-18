/* simple-asr: audio.cpp C ABI shim。
 * audio.cpp 是纯 C++ 库（Registry/Model/Session 类体系），无官方 C 接口；
 * 此 shim 暴露最小转写面供 Rust FFI 使用。句柄与字符串的所有权约定：
 *   - acpp_model_load 返回的句柄由 acpp_model_free 释放
 *   - out_text/out_lang 由 acpp_free_string 释放
 */
#ifndef AUDIOCPP_C_H
#define AUDIOCPP_C_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 最近一次错误的线程局部消息（失败返回后有效，下次调用可能失效） */
const char *acpp_last_error(void);

/* 加载模型（-hf 目录或单文件 GGUF）。family_hint 传 "qwen3_asr"。
 * 成功返回不透明句柄，失败返回 NULL（详见 acpp_last_error）。 */
void *acpp_model_load(const char *model_path, const char *family_hint);

void acpp_model_free(void *model);

/* 离线转写：16kHz 单声道 f32 PCM。
 * backend: "cpu"|"cuda"|"hip"|"vulkan"|"metal"；language 空串 = 自动检测。
 * 成功返回 0 并写出 out_text/out_lang 两串，失败返回 -1。 */
int acpp_transcribe(void *model,
                    const float *samples,
                    size_t sample_count,
                    const char *backend,
                    int device,
                    int threads,
                    const char *language,
                    char **out_text,
                    char **out_lang);

void acpp_free_string(char *s);

/* ── 流式转写 ──
 * 生命周期：acpp_stream_start → 多次 acpp_stream_push（每次同步返回一个事件，
 * *out_text 为增量文本，非 NULL 时须 acpp_free_string）→ acpp_stream_finish
 * （返回权威全文）→ acpp_stream_free。
 */
void *acpp_stream_start(void *model,
                        const char *backend,
                        int device,
                        int threads,
                        const char *language,
                        double chunk_seconds,
                        long long total_samples);

/* 推送一段 16k 单声道 PCM。返回 0 成功（事件经 out 参数给出）：
 * *has_text=1 时 *out_text 为本次增量（需释放）；*is_final 为该事件的结束标记。 */
int acpp_stream_push(void *stream,
                     const float *samples,
                     size_t sample_count,
                     char **out_text,
                     int *has_text,
                     int *is_final);

/* 结束会话，返回权威全文。 */
int acpp_stream_finish(void *stream, char **out_text, char **out_lang);

void acpp_stream_free(void *stream);

/* ── 说话人分离 ──
 * 输入 16k 单声道 PCM，输出 JSON 数组字符串（调用方 acpp_free_string）：
 *   [{"start_sec":..,"end_sec":..,"speaker":"SPEAKER_00"}, ...]
 * 内部按模型固定窗口（默认 20s）分窗推理并做时间偏移与相邻同说话人合并。
 * 注意：跨窗说话人编号可能重标（无音色聚类），窗边界偶有归属漂移。
 * model 须为 sortformer_diar 句柄。 */
int acpp_diarize(void *model,
                 const float *samples,
                 size_t sample_count,
                 const char *backend,
                 int device,
                 int threads,
                 char **out_json);

/* ── 词级强制对齐 ──
 * model 须为 qwen3_forced_aligner 句柄。给定 16k 单声道 PCM 与其转写文本，
 * 输出逐词时间戳 JSON（调用方 acpp_free_string）：
 *   [{"start_sec":..,"end_sec":..,"word":"..","confidence":..}, ...]
 * language 传 "" 表示沿用转写检测语言（建议显式传，如 "Chinese"/"auto"）。
 */
int acpp_align(void *model,
               const float *samples,
               size_t sample_count,
               const char *text,
               const char *language,
               const char *backend,
               int device,
               int threads,
               char **out_json);

#ifdef __cplusplus
}
#endif

#endif /* AUDIOCPP_C_H */
