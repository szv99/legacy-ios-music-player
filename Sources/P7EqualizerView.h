#import <UIKit/UIKit.h>

// Animated "now playing" bars. Bounce while animating, rest low when paused.
// Uses tintColor unless barColor is set.
@interface P7EqualizerView : UIView
@property (nonatomic) BOOL animating;
@property (nonatomic, strong) UIColor *barColor;
@end
