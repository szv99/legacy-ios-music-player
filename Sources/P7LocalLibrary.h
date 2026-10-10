#import <Foundation/Foundation.h>

// The library of the "This iPhone" backend: imported playlists / albums / artists, the songs
// added to "Songs", and pictures of artists, albums and playlists. A port of the Player7
// server's Store (server/library.py), kept as JSON in Library/Application Support/Player7/Library.
//
// Tracks, playlists and entities use the server's internal shapes:
//   track    {id, title, artist, album, albumId, duration, source, youtubeId, coverUrl, artistRefs}
//   playlist {id, name, source, kind, owner, url, trackIds, importedAt}
//   entity   {id, kind, name, subtitle, source, image, url}
// The public* methods turn them into the JSON the app reads (server's public_track etc.).
// Thread-safe.
@interface P7LocalLibrary : NSObject

+ (instancetype)shared;

- (NSDictionary *)trackForID:(NSString *)trackID;
- (void)upsertTracks:(NSArray *)tracks;    // fields that are empty don't overwrite known ones

- (NSArray *)playlists;                    // stored playlists, by name
- (NSDictionary *)playlistForID:(NSString *)playlistID;
- (NSDictionary *)savePlaylist:(NSDictionary *)playlist tracks:(NSArray *)tracks;
- (void)deletePlaylistID:(NSString *)playlistID;
- (NSArray *)tracksOfPlaylist:(NSDictionary *)playlist;

- (BOOL)isAdded:(NSString *)trackID;
- (void)setTrackID:(NSString *)trackID added:(BOOL)added;
- (NSArray *)libraryTracks;                // added songs, then songs of stored playlists

- (NSString *)imageForID:(NSString *)entityID;
- (void)setImage:(NSString *)url forID:(NSString *)entityID replace:(BOOL)replace;

- (NSDictionary *)publicTrack:(NSDictionary *)track;
- (NSArray *)publicTracks:(NSArray *)tracks;
// tracks nil: the stored playlist's own songs.
- (NSDictionary *)publicPlaylist:(NSDictionary *)playlist withTracks:(BOOL)withTracks tracks:(NSArray *)tracks;
- (NSDictionary *)publicEntity:(NSDictionary *)entity;   // also remembers its picture

@end

NSString *P7ShortHash(NSString *string);   // first 8 hex digits of the MD5, like the server's coverVersion
