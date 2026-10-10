#import <UIKit/UIKit.h>
#import "P7Models.h"

// Opens artist pages and album / playlist previews from anywhere, including the
// Now Playing screen (which is dismissed first so the page lands in the current tab).
@interface P7Navigator : NSObject
+ (void)openEntity:(P7Entity *)entity from:(UIViewController *)controller;
// Asks the server who made the song; one artist opens directly, several ask which.
+ (void)openArtistOfTrack:(P7Track *)track from:(UIViewController *)controller;
+ (void)openAlbumOfTrack:(P7Track *)track from:(UIViewController *)controller;
@end
