#import <UIKit/UIKit.h>

extern NSString *const P7MiniPlayerDidChangeNotification;   // shown or hidden

// Bar above the tab bar with the current song: tap or swipe up for Now Playing,
// play / pause and next on the right, a thin progress line along the top.
@interface P7MiniPlayer : UIView
+ (instancetype)attachToTabBarController:(UITabBarController *)tabBarController;
+ (CGFloat)visibleHeight;   // 0 while hidden; lists add it to their bottom inset
@end

@interface UIViewController (P7MiniPlayer)
// Keeps the last rows of a list scrollable above the mini player.
- (void)p7_adjustInsetsForMiniPlayer:(UIScrollView *)scrollView;
@end
