#import <Foundation/Foundation.h>

// Bytes start...end of the original file, or nil when they can't be loaded.
typedef NSData *(^P7RangeFetcher)(long long start, long long end);
// Several ranges of the original in one request: [@[@start, @end], ...] -> one NSData per range,
// or nil when the source doesn't do that.
typedef NSArray *(^P7RangesFetcher)(NSArray *ranges);

// YouTube serves its audio as fragmented MP4 (DASH): an empty index at the start and the audio in
// ten-second pieces, each with its own small index. AVPlayer only plays that from iOS 10 on, and
// newer versions report twice the real length. So the in-app server hands the player a regular MP4
// instead: one index (moov) for the whole song, followed by the audio of every piece, copied byte
// for byte. Nothing is re-encoded, and any byte range of the regular file can be served at once.
@interface P7FragmentedMP4 : NSObject

// YES if `head`, the start of a file, is a fragmented MP4.
+ (BOOL)isFragmented:(NSData *)head;

// Reads the small index of every piece (a couple of kilobytes each), many per request when
// rangesFetcher (optional) can. nil if the file isn't laid out as expected.
- (instancetype)initWithHead:(NSData *)head length:(long long)length fetcher:(P7RangeFetcher)fetcher rangesFetcher:(P7RangesFetcher)rangesFetcher;

@property (nonatomic, readonly) long long length;           // of the regular MP4
@property (nonatomic, readonly) long long originalLength;

// Writes bytes start...end of the regular MP4, fetching at most `firstChunk` bytes of the original
// at first and `chunk` bytes after that. NO when a fetch or a write fails.
- (BOOL)copyFrom:(long long)start to:(long long)end fetcher:(P7RangeFetcher)fetcher firstChunk:(long long)firstChunk chunk:(long long)chunk write:(BOOL (^)(NSData *data))write;

@end
