#import <UIKit/UIKit.h>

extern NSString *const P7ImageCacheDidClearNotification;

// Cover art cache: memory (NSCache) + disk (Library/Caches/Covers2), with
// request de-duplication. Covers are keyed by cover key ("<trackId>|<version>") and pixel size;
// the "trackID" parameters below take a cover key (a bare track id also works).
@interface P7ImageCache : NSObject
+ (instancetype)shared;
- (UIImage *)cachedCoverForTrackID:(NSString *)trackID size:(NSInteger)size;
- (void)coverForTrackID:(NSString *)trackID size:(NSInteger)size completion:(void (^)(UIImage *image))completion;
- (void)clearMemory;
- (void)clearAll;   // memory + disk, e.g. after covers changed on the server
- (unsigned long long)diskBytes;
@end

@interface UIImageView (P7Cover)
// Loads the cover into the image view, ignoring stale results after cell reuse.
- (void)p7_setCoverForTrackID:(NSString *)trackID size:(NSInteger)size placeholder:(UIImage *)placeholder;
@end
