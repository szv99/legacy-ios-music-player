#import <Foundation/Foundation.h>

// Thin wrappers around the server's JSON objects. The raw dictionary is kept so
// items can be persisted (offline index) and re-created without loss.

@interface P7Item : NSObject
@property (nonatomic, copy, readonly) NSDictionary *raw;
+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary;
+ (NSArray *)itemsWithArray:(id)array;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSString *)stringForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
@end

@interface P7Track : P7Item
@property (nonatomic, readonly) NSString *trackID;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *artist;
@property (nonatomic, readonly) NSString *album;
@property (nonatomic, readonly) NSString *format;      // file extension served by /stream, e.g. "mp3", "m4a"
@property (nonatomic, readonly) NSInteger duration;    // seconds
@property (nonatomic, readonly) long long size;        // bytes, 0 if unknown
@property (nonatomic, readonly) BOOL available;        // audio is on the server and can be streamed
@property (nonatomic, readonly) NSString *source;      // "local", "spotify", "youtube"
@property (nonatomic, readonly) BOOL cached;           // the server already has the audio file
@property (nonatomic, readonly) BOOL inLibrary;        // explicitly added to "Songs"
@property (nonatomic, readonly) NSString *coverKey;    // "<id>|<coverVersion>", what the image cache is keyed by
@property (nonatomic, readonly) NSString *albumID;     // album page id ("sp-al-…", "yt-al-…"), nil if unknown
@end

@interface P7Playlist : P7Item
@property (nonatomic, readonly) NSString *playlistID;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *source;      // "local", "spotify", "youtube"
@property (nonatomic, readonly) NSInteger trackCount;
@property (nonatomic, readonly) NSInteger duration;
@property (nonatomic, readonly) NSString *coverTrackID; // track whose cover represents the playlist
@property (nonatomic, readonly) NSString *owner;
@property (nonatomic, readonly) BOOL canSync;          // imported from Spotify / YouTube
@property (nonatomic, readonly) NSString *coverKey;
@property (nonatomic, readonly) NSString *kind;        // "playlist", "album", "artist"
@property (nonatomic, readonly) NSString *url;         // source link, used to import a preview
@property (nonatomic, readonly) BOOL imported;         // in the library (previews of albums etc. are not)
@property (nonatomic, readonly) NSArray *tracks;       // P7Track, only filled by /api/playlists/<id>
@end

// An artist, album or playlist on Spotify / YouTube that can be opened (and imported).
@interface P7Entity : P7Item
@property (nonatomic, readonly) NSString *entityID;    // "sp-ar-…", "yt-ch-…", "sp-al-…", "yt-pl-…"
@property (nonatomic, readonly) NSString *kind;        // "artist", "album", "playlist"
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *subtitle;
@property (nonatomic, readonly) NSString *source;
@property (nonatomic, readonly) NSString *url;
@property (nonatomic, readonly) NSString *coverKey;    // nil when there is no picture
@property (nonatomic, readonly) BOOL isArtist;
+ (instancetype)entityWithID:(NSString *)entityID name:(NSString *)name kind:(NSString *)kind;
@end

// A row group on an artist page: songs, or artists / albums.
@interface P7Section : P7Item
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSArray *tracks;       // P7Track
@property (nonatomic, readonly) NSArray *items;        // P7Entity
@property (nonatomic, readonly) P7Entity *more;        // "All Songs" link, may be nil
@end

@interface P7Artist : P7Entity
@property (nonatomic, readonly) NSString *bannerKey;   // wide header picture
@property (nonatomic, readonly) BOOL imported;
@property (nonatomic, readonly) NSArray *sections;     // P7Section
@end

NSString *P7CoverKey(NSString *trackID, NSString *version);
NSString *P7FormatDuration(NSInteger seconds);
NSString *P7FormatLongDuration(NSInteger seconds);
NSString *P7TrackCountString(NSInteger count);
