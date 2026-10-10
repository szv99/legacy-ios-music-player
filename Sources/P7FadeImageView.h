#import <UIKit/UIKit.h>

// Image view that cross-fades whenever its image changes while on screen.
@interface P7FadeImageView : UIImageView
@property (nonatomic) NSTimeInterval fadeDuration;          // default 0.25
@property (nonatomic, copy) void (^imageDidChange)(UIImage *image);
@end
