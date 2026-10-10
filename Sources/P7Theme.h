#import <UIKit/UIKit.h>

// Colors and vector icons in the style of the iOS 7 Music app.
// Icons are template images, so they pick up the view's tintColor.
@interface P7Theme : NSObject

+ (UIColor *)tintColor;
+ (UIColor *)secondaryTextColor;
+ (UIColor *)separatorColor;
+ (void)apply;

+ (UIImage *)placeholderArtworkWithSize:(CGFloat)size;

+ (UIImage *)tabPlaylistsIcon;
+ (UIImage *)tabSongsIcon;
+ (UIImage *)tabOfflineIcon;
+ (UIImage *)tabSettingsIcon;

+ (UIImage *)playIcon;
+ (UIImage *)pauseIcon;
+ (UIImage *)nextIcon;
+ (UIImage *)previousIcon;
+ (UIImage *)smallPlayIcon;
+ (UIImage *)smallPauseIcon;
+ (UIImage *)smallNextIcon;
+ (UIImage *)shuffleIcon;
+ (UIImage *)repeatIcon;
+ (UIImage *)repeatOneIcon;
+ (UIImage *)queueIcon;
+ (UIImage *)chevronDownIcon;
+ (UIImage *)moreIcon;
+ (UIImage *)downloadIcon;
+ (UIImage *)downloadedIcon;
+ (UIImage *)speakerIcon;

@end
