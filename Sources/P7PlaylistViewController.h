#import "P7TableViewController.h"

@interface P7PlaylistViewController : P7TableViewController
- (instancetype)initWithPlaylist:(P7Playlist *)playlist;
// An album / playlist from Spotify or YouTube that may not be in the library yet; adds an "Add to Library" button.
- (instancetype)initWithEntity:(P7Entity *)entity;
@end
