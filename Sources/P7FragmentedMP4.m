#import "P7FragmentedMP4.h"

static const long long kFragmentWindow = 4096;     // a ten-second piece's index is about 1.8 KB
static const NSUInteger kRangesPerRequest = 48;    // googlevideo answers 416 to more than 50
static const long kParallelFetches = 4;

// Audio samples stored back to back: `length` bytes at `source` in the original file,
// at `offset` in the regular one.
@interface P7MP4Run : NSObject {
@public
	long long source, offset, length;
	uint32_t samples;
}
@end

@implementation P7MP4Run
@end

// What one piece of the original adds: its runs, and the size and duration of each sample.
@interface P7MP4Fragment : NSObject
@property (nonatomic) NSMutableArray *runs;
@property (nonatomic) NSMutableData *sizes;       // uint32_t each
@property (nonatomic) NSMutableData *durations;   // uint32_t each
@property (nonatomic) long long next;             // where the following piece starts
@end

@implementation P7MP4Fragment
@end

#pragma mark - Reading boxes

typedef struct {
	long long start, body, end;   // body: the first byte after the header
	uint32_t type;
} P7Box;

static uint32_t P7Type(const char *name) {
	return (uint32_t)(uint8_t)name[0] << 24 | (uint32_t)(uint8_t)name[1] << 16 | (uint32_t)(uint8_t)name[2] << 8 | (uint8_t)name[3];
}

static uint32_t P7Read32(const uint8_t *p) {
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint64_t P7Read64(const uint8_t *p) {
	return (uint64_t)P7Read32(p) << 32 | P7Read32(p + 4);
}

// The header of the box at `at` in data; the box may end past the data, but not past `limit`.
static BOOL P7ReadBox(NSData *data, long long at, long long limit, P7Box *box) {
	const uint8_t *bytes = data.bytes;
	long long length = (long long)data.length;
	if (at < 0 || at + 8 > length) return NO;
	uint64_t size = P7Read32(bytes + at);
	box->type = P7Read32(bytes + at + 4);
	box->body = at + 8;
	if (size == 1) {
		if (at + 16 > length) return NO;
		size = P7Read64(bytes + at + 8);
		box->body = at + 16;
	} else if (size == 0) {
		size = (uint64_t)(limit - at);
	}
	if (size < (uint64_t)(box->body - at) || size > (uint64_t)(limit - at)) return NO;
	box->start = at;
	box->end = at + (long long)size;
	return YES;
}

// The first box of `type` between `from` and `to`, if it lies wholly within the data.
static BOOL P7FindBox(NSData *data, long long from, long long to, const char *type, P7Box *found) {
	P7Box box;
	for (long long at = from; at < to && P7ReadBox(data, at, to, &box); at = box.end) {
		if (box.type == P7Type(type)) {
			*found = box;
			return box.end <= (long long)data.length;
		}
	}
	return NO;
}

// Follows a path like "trak/mdia/mdhd" down from the body of `parent`.
static BOOL P7FindPath(NSData *data, P7Box parent, const char *path, P7Box *found) {
	P7Box box = parent;
	for (const char *name = path; ; name += 5) {
		if (!P7FindBox(data, box.body, box.end, name, &box)) return NO;
		if (name[4] != '/') break;
	}
	*found = box;
	return YES;
}

#pragma mark - Writing boxes

static void P7Put16(NSMutableData *data, uint16_t value) {
	uint8_t bytes[2] = {value >> 8, value & 0xff};
	[data appendBytes:bytes length:2];
}

static void P7Put32(NSMutableData *data, uint32_t value) {
	uint8_t bytes[4] = {value >> 24, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff};
	[data appendBytes:bytes length:4];
}

static void P7PutMatrix(NSMutableData *data) {
	const uint32_t identity[9] = {0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000};
	for (int i = 0; i < 9; i++) P7Put32(data, identity[i]);
}

// Starts a box whose size is filled in by P7End.
static NSUInteger P7Begin(NSMutableData *data, const char *type) {
	NSUInteger start = data.length;
	P7Put32(data, 0);
	[data appendBytes:type length:4];
	return start;
}

static void P7End(NSMutableData *data, NSUInteger start) {
	uint32_t size = (uint32_t)(data.length - start);
	uint8_t bytes[4] = {size >> 24, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff};
	[data replaceBytesInRange:NSMakeRange(start, 4) withBytes:bytes];
}

@implementation P7FragmentedMP4 {
	NSData *_header;     // ftyp, moov and the mdat header of the regular file
	NSArray *_runs;      // P7MP4Run, in file order
	uint32_t _trackID, _defaultDuration, _defaultSize;
}

+ (BOOL)isFragmented:(NSData *)head {
	P7Box box, child;
	for (long long at = 0; P7ReadBox(head, at, LLONG_MAX / 2, &box); at = box.end) {
		if (box.type != P7Type("moov")) continue;
		// mvex announces the pieces. It comes before the tracks, so it's there even when head ends inside moov.
		for (long long inner = box.body; P7ReadBox(head, inner, box.end, &child); inner = child.end) {
			if (child.type == P7Type("mvex")) return YES;
		}
		return NO;
	}
	return NO;
}

- (instancetype)initWithHead:(NSData *)head length:(long long)length fetcher:(P7RangeFetcher)fetcher rangesFetcher:(P7RangesFetcher)rangesFetcher {
	if (!(self = [super init])) return nil;
	_originalLength = length;

	// The boxes before the first piece: ftyp, moov, and usually sidx, the list of pieces.
	P7Box box, moov = {0}, sidx = {0};
	BOOL hasMoov = NO, hasSidx = NO;
	long long at = 0;
	while (at < length) {
		BOOL complete = P7ReadBox(head, at, length, &box);
		if (complete && (box.type == P7Type("moof") || box.type == P7Type("mdat"))) break;
		if (!complete || box.end > (long long)head.length) {
			if (complete && box.type != P7Type("moov") && box.type != P7Type("sidx")) {
				at = box.end;   // skipped without reading it
				continue;
			}
			long long want = MIN(length, MAX(complete ? box.end : 0, (long long)head.length * 2 + 4096)) - 1;
			NSData *more = (long long)head.length < length ? fetcher(0, want) : nil;
			if (more.length <= head.length) return nil;
			head = more;
			continue;
		}
		if (box.type == P7Type("moov")) { moov = box; hasMoov = YES; }
		if (box.type == P7Type("sidx") && !hasSidx) { sidx = box; hasSidx = YES; }
		at = box.end;
	}
	if (!hasMoov) return nil;
	const uint8_t *bytes = head.bytes;

	P7Box mdhd, stsd, trex, elst;
	if (!P7FindPath(head, moov, "trak/mdia/mdhd", &mdhd) || !P7FindPath(head, moov, "trak/mdia/minf/stbl/stsd", &stsd) || !P7FindPath(head, moov, "mvex/trex", &trex)) return nil;
	BOOL longTimes = bytes[mdhd.body] == 1;
	if (mdhd.end - mdhd.body < (longTimes ? 36 : 24) || trex.end - trex.body < 24) return nil;
	uint32_t timescale = P7Read32(bytes + mdhd.body + (longTimes ? 20 : 12));
	uint16_t language = (uint16_t)(P7Read32(bytes + mdhd.body + (longTimes ? 32 : 20)) >> 16);
	_trackID = P7Read32(bytes + trex.body + 4);
	_defaultDuration = P7Read32(bytes + trex.body + 12);
	_defaultSize = P7Read32(bytes + trex.body + 16);
	if (!timescale) return nil;

	// The edit list skips the encoder's priming samples at the start.
	long long mediaTime = -1;
	if (P7FindPath(head, moov, "trak/edts/elst", &elst) && elst.end - elst.body >= 8 && P7Read32(bytes + elst.body + 4) >= 1) {
		BOOL longEdit = bytes[elst.body] == 1;
		if (elst.end - elst.body >= (longEdit ? 28 : 20)) mediaTime = longEdit ? (int64_t)P7Read64(bytes + elst.body + 16) : (int32_t)P7Read32(bytes + elst.body + 12);
	}

	// Where each piece starts. Without a usable sidx, walk the pieces one after another.
	NSMutableArray *starts = nil;
	if (hasSidx) {
		long long q = sidx.body + 12;
		BOOL longOffsets = bytes[sidx.body] == 1;
		if (q + (longOffsets ? 20 : 12) <= sidx.end) {
			long long position = sidx.end + (long long)(longOffsets ? P7Read64(bytes + q + 8) : P7Read32(bytes + q + 4));
			q += longOffsets ? 18 : 10;
			uint16_t count = (uint16_t)(bytes[q] << 8 | bytes[q + 1]);
			q += 2;
			starts = [NSMutableArray new];
			for (uint16_t i = 0; i < count && starts; i++, q += 12) {
				uint32_t reference = q + 12 <= sidx.end ? P7Read32(bytes + q) : 0x80000000;
				if (reference & 0x80000000) starts = nil;   // points to another sidx
				[starts addObject:@(position)];
				position += reference & 0x7fffffff;
			}
		}
	}

	NSMutableArray *fragments = [NSMutableArray new];
	if (starts.count) {
		NSMutableArray *results = [NSMutableArray new];
		for (NSUInteger i = 0; i < starts.count; i++) [results addObject:[NSNull null]];
		dispatch_group_t group = dispatch_group_create();
		dispatch_semaphore_t slots = dispatch_semaphore_create(kParallelFetches);
		__block BOOL failed = NO;
		for (NSUInteger first = 0; first < starts.count && !failed; first += kRangesPerRequest) {
			dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
			NSArray *batch = [starts subarrayWithRange:NSMakeRange(first, MIN(kRangesPerRequest, starts.count - first))];
			dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				NSMutableArray *windows = [NSMutableArray new];
				for (NSNumber *start in batch) [windows addObject:@[start, @(MIN(length, start.longLongValue + kFragmentWindow) - 1)]];
				NSArray *found = rangesFetcher && batch.count > 1 ? rangesFetcher(windows) : nil;
				for (NSUInteger i = 0; i < batch.count && !failed; i++) {
					NSData *window = found.count == batch.count ? found[i] : nil;
					P7MP4Fragment *fragment = [self fragmentAt:[batch[i] longLongValue] window:window fetcher:fetcher];
					@synchronized (results) {
						if (fragment) results[first + i] = fragment;
						else failed = YES;
					}
				}
				dispatch_semaphore_signal(slots);
			});
		}
		dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
		if (failed) return nil;
		[fragments addObjectsFromArray:results];
	} else {
		while (at < length) {
			P7MP4Fragment *fragment = [self fragmentAt:at window:nil fetcher:fetcher];
			if (!fragment || fragment.next <= at) return nil;
			[fragments addObject:fragment];
			at = fragment.next;
		}
	}

	NSMutableArray *runs = [NSMutableArray new];
	NSMutableData *sizes = [NSMutableData new], *durations = [NSMutableData new];
	for (P7MP4Fragment *fragment in fragments) {
		[runs addObjectsFromArray:fragment.runs];
		[sizes appendData:fragment.sizes];
		[durations appendData:fragment.durations];
	}
	long long payload = 0;
	for (P7MP4Run *run in runs) {
		if (run->source < payload) return nil;   // out of order or overlapping
		payload = run->source + run->length;
	}
	if (!runs.count) return nil;
	_runs = runs;
	if (![self buildHeaderWithStsd:[head subdataWithRange:NSMakeRange((NSUInteger)stsd.start, (NSUInteger)(stsd.end - stsd.start))] timescale:timescale language:language mediaTime:mediaTime sizes:sizes durations:durations]) return nil;
	return self;
}

// Reads the index (moof) of the piece at `offset` in the original. `window`, if given, holds its first bytes.
- (P7MP4Fragment *)fragmentAt:(long long)offset window:(NSData *)window fetcher:(P7RangeFetcher)fetcher {
	P7MP4Fragment *fragment = [P7MP4Fragment new];
	fragment.runs = [NSMutableArray new];
	fragment.sizes = [NSMutableData new];
	fragment.durations = [NSMutableData new];
	fragment.next = _originalLength;
	while (offset < _originalLength) {
		long long limit = _originalLength - offset;
		NSData *data = window ?: fetcher(offset, MIN(_originalLength, offset + kFragmentWindow) - 1);
		window = nil;
		P7Box moof, mdat;
		if (!P7ReadBox(data, 0, limit, &moof)) return nil;
		if (moof.type != P7Type("moof")) {   // styp, emsg, ...
			offset += moof.end;
			continue;
		}
		long long wanted = MIN(moof.end + 16, limit);   // the index and the header of the mdat after it
		if ((long long)data.length < wanted) {           // a larger index than usual
			data = fetcher(offset, offset + wanted - 1);
			if ((long long)data.length < moof.end) return nil;
		}
		if (![self readMoof:moof of:data at:offset into:fragment]) return nil;
		fragment.next = offset + moof.end;
		if (P7ReadBox(data, moof.end, limit, &mdat) && mdat.type == P7Type("mdat")) fragment.next = offset + mdat.end;
		return fragment;
	}
	return fragment;
}

- (BOOL)readMoof:(P7Box)moof of:(NSData *)data at:(long long)offset into:(P7MP4Fragment *)fragment {
	const uint8_t *bytes = data.bytes;
	P7Box traf, tfhd, trun;
	for (long long at = moof.body; P7ReadBox(data, at, moof.end, &traf); at = traf.end) {
		if (traf.type != P7Type("traf")) continue;
		if (!P7FindBox(data, traf.body, traf.end, "tfhd", &tfhd) || tfhd.end - tfhd.body < 8) return NO;
		const uint8_t *header = bytes + tfhd.body;
		uint32_t flags = P7Read32(header) & 0xffffff;
		if (P7Read32(header + 4) != _trackID) continue;
		long long base = offset + moof.start, q = 8;
		uint32_t defaultDuration = _defaultDuration, defaultSize = _defaultSize;
		long long needed = 8 + (flags & 0x1 ? 8 : 0) + (flags & 0x2 ? 4 : 0) + (flags & 0x8 ? 4 : 0) + (flags & 0x10 ? 4 : 0);
		if (tfhd.end - tfhd.body < needed) return NO;
		if (flags & 0x1) { base = (long long)P7Read64(header + q); q += 8; }
		if (flags & 0x2) q += 4;
		if (flags & 0x8) { defaultDuration = P7Read32(header + q); q += 4; }
		if (flags & 0x10) defaultSize = P7Read32(header + q);

		long long next = base;   // a run without a data offset starts where the previous one ended
		for (long long inner = traf.body; P7ReadBox(data, inner, traf.end, &trun); inner = trun.end) {
			if (trun.type != P7Type("trun")) continue;
			if (trun.end > (long long)data.length || trun.end - trun.body < 8) return NO;
			const uint8_t *run = bytes + trun.body;
			uint32_t runFlags = P7Read32(run) & 0xffffff, count = P7Read32(run + 4);
			long long r = 8, start = next;
			if (runFlags & 0x1) {
				if (trun.end - trun.body < 12) return NO;
				start = base + (int32_t)P7Read32(run + r);
				r += 4;
			}
			if (runFlags & 0x4) r += 4;
			long long entry = 4 * (!!(runFlags & 0x100) + !!(runFlags & 0x200) + !!(runFlags & 0x400) + !!(runFlags & 0x800));
			if (trun.body + r + (long long)count * entry > trun.end) return NO;
			long long total = 0;
			for (uint32_t i = 0; i < count; i++) {
				uint32_t duration = defaultDuration, size = defaultSize;
				if (runFlags & 0x100) { duration = P7Read32(run + r); r += 4; }
				if (runFlags & 0x200) { size = P7Read32(run + r); r += 4; }
				r += 4 * (!!(runFlags & 0x400) + !!(runFlags & 0x800));
				[fragment.durations appendBytes:&duration length:4];
				[fragment.sizes appendBytes:&size length:4];
				total += size;
			}
			if (start < 0 || start + total > _originalLength) return NO;
			if (count) {
				P7MP4Run *stretch = [P7MP4Run new];
				stretch->source = start;
				stretch->length = total;
				stretch->samples = count;
				[fragment.runs addObject:stretch];
			}
			next = start + total;
		}
	}
	return YES;
}

// ftyp, then a moov listing every sample, then the mdat header. Each run becomes one chunk.
- (BOOL)buildHeaderWithStsd:(NSData *)stsd timescale:(uint32_t)timescale language:(uint16_t)language mediaTime:(long long)mediaTime sizes:(NSData *)sizes durations:(NSData *)durations {
	NSUInteger sampleCount = sizes.length / 4;
	const uint32_t *sampleSizes = sizes.bytes, *sampleDurations = durations.bytes;
	uint64_t total = 0;
	for (NSUInteger i = 0; i < sampleCount; i++) total += sampleDurations[i];
	long long payload = 0;
	for (P7MP4Run *run in _runs) payload += run->length;
	BOOL edit = mediaTime >= 0 && (uint64_t)mediaTime < total;
	uint64_t shown = edit ? total - (uint64_t)mediaTime : total;
	if (total > UINT32_MAX) return NO;

	NSMutableData *h = [NSMutableData new];
	NSUInteger ftyp = P7Begin(h, "ftyp");
	[h appendBytes:"M4A " length:4];
	P7Put32(h, 0);
	[h appendBytes:"M4A mp42isom" length:12];
	P7End(h, ftyp);

	NSUInteger moov = P7Begin(h, "moov");
	NSUInteger mvhd = P7Begin(h, "mvhd");
	P7Put32(h, 0); P7Put32(h, 0); P7Put32(h, 0);   // version and flags, creation and modification times
	P7Put32(h, timescale);
	P7Put32(h, (uint32_t)shown);
	P7Put32(h, 0x10000); P7Put16(h, 0x100);         // rate, volume
	[h increaseLengthBy:10];
	P7PutMatrix(h);
	[h increaseLengthBy:24];
	P7Put32(h, 2);                                  // next track ID
	P7End(h, mvhd);

	NSUInteger trak = P7Begin(h, "trak");
	NSUInteger tkhd = P7Begin(h, "tkhd");
	P7Put32(h, 3);                                  // enabled, in movie
	P7Put32(h, 0); P7Put32(h, 0);
	P7Put32(h, 1);                                  // track ID
	P7Put32(h, 0);
	P7Put32(h, (uint32_t)shown);
	[h increaseLengthBy:8];
	P7Put16(h, 0); P7Put16(h, 0); P7Put16(h, 0x100); P7Put16(h, 0);   // layer, group, volume
	P7PutMatrix(h);
	P7Put32(h, 0); P7Put32(h, 0);                   // width, height
	P7End(h, tkhd);
	if (edit) {
		NSUInteger edts = P7Begin(h, "edts"), elst = P7Begin(h, "elst");
		P7Put32(h, 0); P7Put32(h, 1);
		P7Put32(h, (uint32_t)shown); P7Put32(h, (uint32_t)mediaTime);
		P7Put16(h, 1); P7Put16(h, 0);
		P7End(h, elst);
		P7End(h, edts);
	}

	NSUInteger mdia = P7Begin(h, "mdia");
	NSUInteger mdhd = P7Begin(h, "mdhd");
	P7Put32(h, 0); P7Put32(h, 0); P7Put32(h, 0);
	P7Put32(h, timescale);
	P7Put32(h, (uint32_t)total);
	P7Put16(h, language); P7Put16(h, 0);
	P7End(h, mdhd);
	NSUInteger hdlr = P7Begin(h, "hdlr");
	P7Put32(h, 0); P7Put32(h, 0);
	[h appendBytes:"soun" length:4];
	[h increaseLengthBy:12];
	[h appendBytes:"SoundHandler" length:13];
	P7End(h, hdlr);

	NSUInteger minf = P7Begin(h, "minf");
	NSUInteger smhd = P7Begin(h, "smhd");
	P7Put32(h, 0); P7Put32(h, 0);
	P7End(h, smhd);
	NSUInteger dinf = P7Begin(h, "dinf"), dref = P7Begin(h, "dref");
	P7Put32(h, 0); P7Put32(h, 1);
	NSUInteger url = P7Begin(h, "url ");
	P7Put32(h, 1);                                  // the data is in this file
	P7End(h, url);
	P7End(h, dref);
	P7End(h, dinf);

	NSUInteger stbl = P7Begin(h, "stbl");
	[h appendData:stsd];

	NSMutableData *entries = [NSMutableData new];
	uint32_t entryCount = 0;
	for (NSUInteger i = 0; i < sampleCount; ) {
		NSUInteger same = i + 1;
		while (same < sampleCount && sampleDurations[same] == sampleDurations[i]) same++;
		P7Put32(entries, (uint32_t)(same - i));
		P7Put32(entries, sampleDurations[i]);
		entryCount++;
		i = same;
	}
	NSUInteger stts = P7Begin(h, "stts");
	P7Put32(h, 0); P7Put32(h, entryCount);
	[h appendData:entries];
	P7End(h, stts);

	entries = [NSMutableData new];
	entryCount = 0;
	uint32_t previous = 0;
	for (NSUInteger i = 0; i < _runs.count; i++) {
		P7MP4Run *run = _runs[i];
		if (run->samples == previous) continue;
		P7Put32(entries, (uint32_t)i + 1);
		P7Put32(entries, run->samples);
		P7Put32(entries, 1);
		entryCount++;
		previous = run->samples;
	}
	NSUInteger stsc = P7Begin(h, "stsc");
	P7Put32(h, 0); P7Put32(h, entryCount);
	[h appendData:entries];
	P7End(h, stsc);

	NSUInteger stsz = P7Begin(h, "stsz");
	P7Put32(h, 0); P7Put32(h, 0); P7Put32(h, (uint32_t)sampleCount);
	for (NSUInteger i = 0; i < sampleCount; i++) P7Put32(h, sampleSizes[i]);
	P7End(h, stsz);

	NSUInteger stco = P7Begin(h, "stco");
	P7Put32(h, 0); P7Put32(h, (uint32_t)_runs.count);
	NSUInteger offsets = h.length;
	[h increaseLengthBy:4 * _runs.count];
	P7End(h, stco);

	P7End(h, stbl);
	P7End(h, minf);
	P7End(h, mdia);
	P7End(h, trak);
	P7End(h, moov);

	long long headerLength = (long long)h.length + 8;
	if (headerLength + payload > UINT32_MAX) return NO;
	P7Put32(h, (uint32_t)(8 + payload));
	[h appendBytes:"mdat" length:4];

	long long position = headerLength;
	for (NSUInteger i = 0; i < _runs.count; i++) {
		P7MP4Run *run = _runs[i];
		run->offset = position;
		uint32_t value = (uint32_t)position;
		uint8_t bytes[4] = {value >> 24, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff};
		[h replaceBytesInRange:NSMakeRange(offsets + 4 * i, 4) withBytes:bytes];
		position += run->length;
	}
	_header = h;
	_length = position;
	return YES;
}

#pragma mark - Serving

// The run that holds byte `position` of the regular file.
- (NSUInteger)runIndexAt:(long long)position {
	NSUInteger low = 0, high = _runs.count;
	while (low + 1 < high) {
		NSUInteger middle = (low + high) / 2;
		if (((P7MP4Run *)_runs[middle])->offset <= position) low = middle;
		else high = middle;
	}
	return low;
}

- (BOOL)copyFrom:(long long)start to:(long long)end fetcher:(P7RangeFetcher)fetcher firstChunk:(long long)firstChunk chunk:(long long)chunk write:(BOOL (^)(NSData *data))write {
	end = MIN(end, _length - 1);
	long long position = start;
	if (position < (long long)_header.length && position <= end) {
		long long stop = MIN(end + 1, (long long)_header.length);
		if (!write([_header subdataWithRange:NSMakeRange((NSUInteger)position, (NSUInteger)(stop - position))])) return NO;
		position = stop;
	}
	NSUInteger index = [self runIndexAt:position];
	long long budget = firstChunk;
	while (position <= end && index < _runs.count) {
		// One fetch of the original covers several runs; the piece indexes between them are skipped.
		long long from = -1, to = -1;
		NSMutableArray *pieces = [NSMutableArray new];
		while (position <= end && index < _runs.count) {
			P7MP4Run *run = _runs[index];
			long long source = run->source + (position - run->offset);
			long long count = MIN(run->offset + run->length - position, end - position + 1);
			if (from < 0) {
				from = source;
				count = MIN(count, budget);
			} else if (source + count - from > budget) {
				break;
			}
			[pieces addObject:@[@(source - from), @(count)]];
			to = source + count - 1;
			position += count;
			if (position == run->offset + run->length) index++;
		}
		NSData *data = fetcher(from, to);
		if ((long long)data.length != to - from + 1) return NO;
		for (NSArray *piece in pieces) {
			if (!write([data subdataWithRange:NSMakeRange([piece[0] unsignedIntegerValue], [piece[1] unsignedIntegerValue])])) return NO;
		}
		budget = chunk;
	}
	return YES;
}

@end
