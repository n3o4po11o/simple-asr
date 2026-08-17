// 桩实现：未提供预构建引擎时（docs/metadata 构建），保持链接可通过。
#include "audiocpp_c.h"

extern "C" {
const char *acpp_last_error(void) { return "audiocpp-ffi built without engine"; }
void *acpp_model_load(const char *, const char *) { return nullptr; }
void acpp_model_free(void *) {}
int acpp_transcribe(void *, const float *, size_t, const char *, int, int,
                    const char *, char **, char **) { return -1; }
void acpp_free_string(char *) {}
void *acpp_stream_start(void *, const char *, int, int, const char *, double, long long) { return nullptr; }
int acpp_stream_push(void *, const float *, size_t, char **, int *, int *) { return -1; }
int acpp_stream_finish(void *, char **, char **) { return -1; }
void acpp_stream_free(void *) {}
int acpp_diarize(void *, const float *, size_t, const char *, int, int, char **) { return -1; }
int acpp_align(void *, const float *, size_t, const char *, const char *, const char *, int, int, char **) { return -1; }
}
