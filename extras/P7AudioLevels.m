#import "P7AudioLevels.h"
#import <MediaToolbox/MediaToolbox.h>
#import <Accelerate/Accelerate.h>
#include <notify.h>

static const char *kLevelsName = "com.szv.encore.levels";
enum { kFFTLog2 = 10, kFFTSize = 1 << kFFTLog2, kBands = 7 };

// Per-tap analysis state (lives in the tap's storage; only touched on the audio thread).
typedef struct {
	FFTSetup fft;
	float window[kFFTSize];
	float samples[kFFTSize];     // ring buffer of the newest samples, mono
	UInt32 writeIndex;
	float real[kFFTSize / 2];
	float imag[kFFTSize / 2];
	float magnitudes[kFFTSize / 2];
	UInt32 filled;
	Float64 sampleRate;
	BOOL isFloat;
	BOOL interleaved;
} P7TapState;

static int sToken = -1;
static uint8_t sCounter;

static void P7Publish(uint64_t bands) {
	if (sToken < 0 && notify_register_check(kLevelsName, &sToken) != NOTIFY_STATUS_OK) {
		sToken = -1;
		return;
	}
	sCounter++;
	notify_set_state(sToken, bands | ((uint64_t)sCounter << 56));
}

static void P7TapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
	P7TapState *state = calloc(1, sizeof(P7TapState));
	state->fft = vDSP_create_fftsetup(kFFTLog2, kFFTRadix2);
	vDSP_hann_window(state->window, kFFTSize, vDSP_HANN_NORM);
	*tapStorageOut = state;
}

static void P7TapFinalize(MTAudioProcessingTapRef tap) {
	P7TapState *state = MTAudioProcessingTapGetStorage(tap);
	if (state->fft) vDSP_destroy_fftsetup(state->fft);
	free(state);
}

static void P7TapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
	P7TapState *state = MTAudioProcessingTapGetStorage(tap);
	state->sampleRate = format->mSampleRate ?: 44100;
	state->isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
	state->interleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
	state->filled = 0;
}

static void P7TapUnprepare(MTAudioProcessingTapRef tap) {
}

// Band edges in Hz: bass to air.
static const float kEdges[kBands + 1] = {40, 120, 300, 750, 1800, 4000, 8000, 16000};

static uint64_t P7Analyze(P7TapState *state) {
	// Unroll the ring buffer oldest-first, then window it.
	float ordered[kFFTSize], windowed[kFFTSize];
	UInt32 start = state->writeIndex & (kFFTSize - 1);
	memcpy(ordered, state->samples + start, (kFFTSize - start) * sizeof(float));
	memcpy(ordered + (kFFTSize - start), state->samples, start * sizeof(float));
	vDSP_vmul(ordered, 1, state->window, 1, windowed, 1, kFFTSize);
	DSPSplitComplex split = {state->real, state->imag};
	vDSP_ctoz((DSPComplex *)windowed, 2, &split, 1, kFFTSize / 2);
	vDSP_fft_zrip(state->fft, &split, 1, kFFTLog2, kFFTRadix2);
	vDSP_zvmags(&split, 1, state->magnitudes, 1, kFFTSize / 2);

	uint64_t packed = 0;
	float binWidth = state->sampleRate / kFFTSize;
	for (int band = 0; band < kBands; band++) {
		int from = MAX(1, (int)(kEdges[band] / binWidth));
		int to = MIN(kFFTSize / 2 - 1, MAX(from + 1, (int)(kEdges[band + 1] / binWidth)));
		float sum = 0;
		for (int i = from; i < to; i++) sum += state->magnitudes[i];
		float power = sum / (to - from);
		// dB relative to a loud full-scale band, mapped from -60..0 dB to 0..255;
		// higher bands get a little lift since music has less energy up there.
		float db = 10 * log10f(power + 1e-12f) - 54 + band * 2.5f;
		float level = MAX(0, MIN(1, (db + 60) / 60));
		packed |= (uint64_t)(level * 255) << (band * 8);
	}
	return packed;
}

static dispatch_queue_t P7PublishQueue(void) {
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ queue = dispatch_queue_create("com.szv.player7.levels", DISPATCH_QUEUE_SERIAL); });
	return queue;
}

static void P7TapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags,
                         AudioBufferList *bufferList, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
	if (MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, NULL, numberFramesOut) != noErr) return;
	P7TapState *state = MTAudioProcessingTapGetStorage(tap);
	if (!state->isFloat || !bufferList->mNumberBuffers) return;

	// Mono mix of the first two channels into the sliding window.
	CMItemCount frames = *numberFramesOut;
	float *left = bufferList->mBuffers[0].mData;
	float *right = bufferList->mNumberBuffers > 1 ? bufferList->mBuffers[1].mData : NULL;
	UInt32 stride = state->interleaved ? bufferList->mBuffers[0].mNumberChannels : 1;
	if (!left || !stride) return;
	// While the app is in the background iOS hands over big buffers (~90 ms), so measure every
	// 1024 samples (~43 times a second) and publish those frames spread out over the time they cover.
	uint64_t frames_[32];
	int count = 0;
	for (CMItemCount i = 0; i < frames; i++) {
		float sample = left[i * stride];
		if (state->interleaved && stride > 1) sample = (sample + left[i * stride + 1]) * 0.5f;
		else if (right) sample = (sample + right[i]) * 0.5f;
		state->samples[state->writeIndex++ & (kFFTSize - 1)] = sample;
		if (state->filled < kFFTSize) state->filled++;
		if (state->filled == kFFTSize && (state->writeIndex & 1023) == 0 && count < 32) frames_[count++] = P7Analyze(state);
	}
	double hop = 1024.0 / state->sampleRate;
	for (int i = 0; i < count; i++) {
		uint64_t packed = frames_[i];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * hop * NSEC_PER_SEC)), P7PublishQueue(), ^{ P7Publish(packed); });
	}
}

@implementation P7AudioLevels

+ (void)attachToPlayerItem:(AVPlayerItem *)item {
	if (item.audioMix) return;
	AVAssetTrack *track = [item.asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
	if (!track) return;
	MTAudioProcessingTapCallbacks callbacks = {
		.version = kMTAudioProcessingTapCallbacksVersion_0,
		.clientInfo = NULL,
		.init = P7TapInit,
		.finalize = P7TapFinalize,
		.prepare = P7TapPrepare,
		.unprepare = P7TapUnprepare,
		.process = P7TapProcess,
	};
	MTAudioProcessingTapRef tap = NULL;
	if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) != noErr || !tap) return;
	AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
	parameters.audioTapProcessor = tap;
	CFRelease(tap);
	AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
	mix.inputParameters = @[parameters];
	item.audioMix = mix;
}

+ (void)publishSilence {
	P7Publish(0);
}

@end
