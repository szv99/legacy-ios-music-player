#import <UIKit/UIKit.h>

// Colors and blur derived from cover art, computed off the main thread.
@interface P7ArtworkEffects : NSObject
// Calls back on the main queue with a soft blurred copy and a readable accent color.
+ (void)effectsForImage:(UIImage *)image completion:(void (^)(UIImage *blurred, UIColor *accent))completion;
@end
