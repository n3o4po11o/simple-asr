// sherpa-onnx C API 桩：未拉取预编译库时保持链接通过，调用即报错。
#include <stddef.h>

typedef struct SherpaOnnxOfflineSpeakerDiarization
    SherpaOnnxOfflineSpeakerDiarization;
typedef struct SherpaOnnxOfflineSpeakerDiarizationConfig
    SherpaOnnxOfflineSpeakerDiarizationConfig;
typedef struct SherpaOnnxOfflineSpeakerDiarizationResult
    SherpaOnnxOfflineSpeakerDiarizationResult;
typedef struct SherpaOnnxOfflineSpeakerDiarizationSegment
    SherpaOnnxOfflineSpeakerDiarizationSegment;

const SherpaOnnxOfflineSpeakerDiarization *
SherpaOnnxCreateOfflineSpeakerDiarization(
    const SherpaOnnxOfflineSpeakerDiarizationConfig *config) {
  (void)config;
  return NULL;
}

void SherpaOnnxDestroyOfflineSpeakerDiarization(
    const SherpaOnnxOfflineSpeakerDiarization *sd) {
  (void)sd;
}

const SherpaOnnxOfflineSpeakerDiarizationResult *
SherpaOnnxOfflineSpeakerDiarizationProcess(
    const SherpaOnnxOfflineSpeakerDiarization *sd, const float *samples,
    int32_t n) {
  (void)sd;
  (void)samples;
  (void)n;
  return NULL;
}

void SherpaOnnxOfflineSpeakerDiarizationDestroyResult(
    const SherpaOnnxOfflineSpeakerDiarizationResult *r) {
  (void)r;
}

int32_t SherpaOnnxOfflineSpeakerDiarizationResultGetNumSpeakers(
    const SherpaOnnxOfflineSpeakerDiarizationResult *r) {
  (void)r;
  return 0;
}

int32_t SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(
    const SherpaOnnxOfflineSpeakerDiarizationResult *r) {
  (void)r;
  return 0;
}

const SherpaOnnxOfflineSpeakerDiarizationSegment *
SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(
    const SherpaOnnxOfflineSpeakerDiarizationResult *r) {
  (void)r;
  return NULL;
}

void SherpaOnnxOfflineSpeakerDiarizationDestroySegment(
    const SherpaOnnxOfflineSpeakerDiarizationSegment *s) {
  (void)s;
}
