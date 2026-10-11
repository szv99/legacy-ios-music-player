#import <Foundation/Foundation.h>
#import "P7Models.h"

extern NSString *const P7APIErrorDomain;
extern NSString *const P7LibraryDidChangeNotification;   // a playlist / album / artist was imported or deleted

typedef void (^P7JSONCompletion)(id json, NSError *error);

// Client for the Player7 server JSON API. With the "This iPhone" and Subsonic sources the same
// API is answered by the app's own server on 127.0.0.1 (P7LocalServer), which also handles
// YouTube for the Player7 server unless Settings say otherwise. Songs and pages go to whichever
// server can answer for them (see -serverHandlesItem: in P7API.m).
//   GET  /api/ping
//   GET  /api/playlists                 -> { playlists: [Playlist] }
//   GET  /api/playlists/<id>            -> { playlist: Playlist (with tracks) }
//   GET  /api/tracks?q=<query>          -> { tracks: [Track] }
//   GET  /api/tracks/<id>/stream        -> audio, supports Range
//   GET  /api/tracks/<id>/cover?size=N  -> jpeg/png
//   GET  /api/search?q=&source=&full=1  -> { tracks, artists, albums, playlists } (source: spotify | youtube | soundcloud | subsonic | youtube-videos)
//   GET  /api/artists/<id>              -> { artist: Artist (with sections) }
//   GET  /api/collections/<id>          -> { playlist } album / playlist / artist songs, imported or not
//   GET  /api/tracks/<id>/artists       -> { artists: [Entity] }
//   POST /api/import { url }            -> { playlist: Playlist | null, imported, background }
//   GET  /api/import/status             -> { running, message, done, total }
//   POST /api/playlists/<id>/sync       -> { playlist }
//   POST /api/playlists/<id>/delete
//   POST /api/library { trackId, remove, track }   track: details of a YouTube song found on the phone
//   POST /api/prefetch { ids }
// Every request carries ?token=<token> when a token is configured.
@interface P7API : NSObject

+ (instancetype)shared;

- (NSURL *)URLForPath:(NSString *)path parameters:(NSDictionary *)parameters;
- (NSURL *)streamURLForTrack:(P7Track *)track;
- (NSURL *)coverURLForTrackID:(NSString *)trackID size:(NSInteger)size;

// To the selected source; remote: to the Player7 server instead of the app's own server.
- (NSURLSessionDataTask *)GET:(NSString *)path parameters:(NSDictionary *)parameters completion:(P7JSONCompletion)completion;
- (NSURLSessionDataTask *)GET:(NSString *)path parameters:(NSDictionary *)parameters remote:(BOOL)remote completion:(P7JSONCompletion)completion;
- (NSURLSessionDataTask *)POST:(NSString *)path body:(NSDictionary *)body completion:(P7JSONCompletion)completion;
- (NSURLSessionDataTask *)POST:(NSString *)path body:(NSDictionary *)body remote:(BOOL)remote completion:(P7JSONCompletion)completion;

- (void)pingWithCompletion:(void (^)(NSError *error))completion;
- (void)fetchPlaylistsWithCompletion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)fetchPlaylist:(NSString *)playlistID completion:(void (^)(P7Playlist *playlist, NSError *error))completion;
- (NSURLSessionDataTask *)searchTracks:(NSString *)query completion:(void (^)(NSArray *tracks, NSError *error))completion;
// results: tracks (P7Track), artists / albums / playlists (P7Entity)
- (NSURLSessionDataTask *)search:(NSString *)query source:(NSString *)source completion:(void (^)(NSDictionary *results, NSError *error))completion;
- (void)fetchArtist:(NSString *)artistID completion:(void (^)(P7Artist *artist, NSError *error))completion;
- (void)fetchCollection:(NSString *)collectionID completion:(void (^)(P7Playlist *playlist, NSError *error))completion;
- (void)fetchArtistsForTrack:(P7Track *)track completion:(void (^)(NSArray *artists, NSError *error))completion;
// playlist is nil when the server imports several playlists in the background (profiles, YouTube Music library).
- (void)importURL:(NSString *)url completion:(void (^)(P7Playlist *playlist, BOOL background, NSError *error))completion;
- (void)fetchImportStatusWithCompletion:(void (^)(NSDictionary *status, NSError *error))completion;
- (void)syncPlaylist:(NSString *)playlistID completion:(void (^)(P7Playlist *playlist, NSError *error))completion;
- (void)deletePlaylist:(NSString *)playlistID completion:(void (^)(NSError *error))completion;
- (void)setTrack:(P7Track *)track inLibrary:(BOOL)inLibrary completion:(void (^)(NSError *error))completion;
- (BOOL)isTrackInLibrary:(P7Track *)track;   // track.inLibrary, updated by the calls above
- (void)prefetchTracks:(NSArray *)tracks;

@end
