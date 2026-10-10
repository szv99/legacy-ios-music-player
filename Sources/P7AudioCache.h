#import <Foundation/Foundation.h>
#import "P7Models.h"

extern NSString *const P7AudioCacheDidChangeNotification;

// Automatic song cache: every song you play (and the next one up) is saved on the
// phone, so replays start instantly and work without the server. Least recently
// played songs are evicted when the size limit is reached. Explicit offline
// downloads (P7Downloads) are separate and never evicted.
@interface P7AudioCache : NSObject

+ (instancetype)shared;

@property (nonatomic) unsigned long long limitBytes;   // persisted; default 1 GB

- (NSURL *)fileURLForTrackID:(NSString *)trackID;     // nil when not cached
- (BOOL)isCached:(NSString *)trackID;
- (void)cacheTrack:(P7Track *)track;                   // background download if needed
- (void)markPlayed:(NSString *)trackID;
- (unsigned long long)totalBytes;
- (NSUInteger)count;
- (void)clear;

@end
