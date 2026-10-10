#import <Foundation/Foundation.h>
#import "P7Models.h"

extern NSString *const P7DownloadsDidChangeNotification;   // userInfo: @"trackID" when a single track changed
extern NSString *const P7DownloadProgressNotification;     // userInfo: @"trackID", @"progress" (NSNumber 0..1)

// Offline storage: Documents/Offline/{tracks,covers}/ plus index.plist.
// Downloads run in a background NSURLSession, so they continue while the app is suspended.
// All methods must be called on the main thread, except -coverDataForTrackID:.
@interface P7Downloads : NSObject

+ (instancetype)shared;

- (BOOL)isDownloaded:(NSString *)trackID;
- (BOOL)isDownloading:(NSString *)trackID;
- (float)progressForTrackID:(NSString *)trackID;
- (NSURL *)localURLForTrackID:(NSString *)trackID;
- (NSData *)coverDataForTrackID:(NSString *)trackID;

- (void)downloadTracks:(NSArray *)tracks;
// Re-downloads offline songs the server has since re-encoded in better quality (audioRev changed).
- (void)refreshTracks:(NSArray *)tracks;
- (void)savePlaylist:(P7Playlist *)playlist;        // keeps the playlist offline and downloads its tracks
- (void)removeTrackID:(NSString *)trackID;
- (void)removePlaylistID:(NSString *)playlistID;  // also removes tracks no other saved playlist uses
- (void)cancelAll;

- (BOOL)isPlaylistSaved:(NSString *)playlistID;
- (NSArray *)downloadedTracks;    // P7Track, newest first
- (NSArray *)savedPlaylists;      // P7Playlist with full track lists
- (NSUInteger)activeDownloadCount;
- (long long)totalBytes;

- (void)handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler;

@end
