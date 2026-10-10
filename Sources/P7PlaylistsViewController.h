#import "P7TableViewController.h"

@interface P7PlaylistsViewController : P7TableViewController
@end

// Row used for playlists: artwork, name, "N songs · source", offline checkmark.
@interface P7PlaylistCell : UITableViewCell
- (void)configureWithPlaylist:(P7Playlist *)playlist;
@end
