#import "P7PlaylistViewController.h"
#import "P7API.h"
#import "P7Player.h"
#import "P7Downloads.h"
#import "P7ImageCache.h"
#import "P7Blocks.h"
#import "P7Theme.h"
#import "P7FadeImageView.h"
#import "P7ArtworkEffects.h"
#import "P7Navigator.h"

@interface P7PlaylistViewController () <UISearchBarDelegate>
@end

@implementation P7PlaylistViewController {
	P7Playlist *_playlist;
	NSArray *_tracks;
	P7FadeImageView *_artworkView;
	P7FadeImageView *_headerBackground;
	UILabel *_nameLabel;
	UILabel *_infoLabel;
	UIButton *_offlineButton;
	UILabel *_offlineLabel;
	UIButton *_addButton;
	BOOL _fromEntity;     // opened from search / an artist page: loaded through /api/collections
	BOOL _importing;
	UIView *_header;
	UISearchBar *_filterBar;    // long playlists get a filter under the header
	NSString *_filter;
	NSArray *_shownCache;       // filter result for _shownFilter / _shownSource
	NSString *_shownFilter;
	NSArray *_shownSource;
}

- (instancetype)initWithPlaylist:(P7Playlist *)playlist {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		_playlist = playlist;
		_tracks = playlist.tracks;
		self.title = playlist.name;
	}
	return self;
}

- (instancetype)initWithEntity:(P7Entity *)entity {
	NSMutableDictionary *raw = [@{@"id": entity.entityID ?: @"", @"name": entity.name ?: @"", @"kind": entity.kind ?: @"playlist", @"imported": @NO} mutableCopy];
	if (entity.url) raw[@"url"] = entity.url;
	if (entity.source) raw[@"source"] = entity.source;
	if (entity.coverKey) {
		raw[@"coverTrackId"] = entity.entityID;
		raw[@"coverVersion"] = [entity stringForKey:@"coverVersion"] ?: @"";
	}
	if ((self = [self initWithPlaylist:[P7Playlist itemWithDictionary:raw]])) {
		_fromEntity = YES;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_header = [self buildHeader];
	self.tableView.tableHeaderView = _header;
	self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
	self.refreshControl = [UIRefreshControl new];
	[self.refreshControl addTarget:self action:@selector(syncWithSource) forControlEvents:UIControlEventValueChanged];
	[self updateHeader];
	[self reload];
}

// Pull to refresh re-imports the playlist from Spotify / YouTube, then shows the result.
- (void)syncWithSource {
	if (!_playlist.canSync || !_playlist.imported) {
		[self reload];
		return;
	}
	self.refreshControl.attributedTitle = [[NSAttributedString alloc] initWithString:@"Syncing with source…"];
	[[P7API shared] syncPlaylist:_playlist.playlistID completion:^(P7Playlist *playlist, NSError *error) {
		self.refreshControl.attributedTitle = nil;
		if (error) {
			[self endRefreshing];
			[P7Alert showError:error title:@"Sync Failed"];
			return;
		}
		[self reload];
	}];
}

#pragma mark - Header

- (UIButton *)borderedButton:(NSString *)title action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setTitle:title forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont systemFontOfSize:15];
	button.layer.borderWidth = 1;
	button.layer.cornerRadius = 4;
	button.layer.borderColor = [P7Theme tintColor].CGColor;
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return button;
}

- (UIView *)buildHeader {
	CGFloat width = self.view.bounds.size.width;
	CGFloat height = _fromEntity ? 197 : 151;
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
	header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

	header.clipsToBounds = YES;
	_headerBackground = [[P7FadeImageView alloc] initWithFrame:CGRectInset(header.bounds, -20, -20)];
	_headerBackground.fadeDuration = 0.5;
	_headerBackground.contentMode = UIViewContentModeScaleAspectFill;
	_headerBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[header addSubview:_headerBackground];
	UIView *wash = [[UIView alloc] initWithFrame:header.bounds];
	wash.backgroundColor = [UIColor colorWithWhite:1 alpha:0.78];
	wash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[header addSubview:wash];

	_artworkView = [[P7FadeImageView alloc] initWithFrame:CGRectMake(15, 15, 120, 120)];
	_artworkView.contentMode = UIViewContentModeScaleAspectFill;
	_artworkView.clipsToBounds = YES;
	[header addSubview:_artworkView];
	__weak P7FadeImageView *background = _headerBackground;
	_artworkView.imageDidChange = ^(UIImage *image) {
		[P7ArtworkEffects effectsForImage:image completion:^(UIImage *blurred, UIColor *accent) {
			background.image = blurred;
		}];
	};

	CGFloat x = 148;
	CGFloat textWidth = width - x - 12;
	_nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, 15, textWidth, 42)];
	_nameLabel.font = [UIFont boldSystemFontOfSize:17];
	_nameLabel.numberOfLines = 2;
	[header addSubview:_nameLabel];

	_infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, 56, textWidth - 40, 48)];
	_infoLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_infoLabel.font = [UIFont systemFontOfSize:13];
	_infoLabel.textColor = [P7Theme secondaryTextColor];
	_infoLabel.numberOfLines = 3;
	[header addSubview:_infoLabel];

	UIButton *play = [self borderedButton:@"Play" action:@selector(playTapped)];
	play.frame = CGRectMake(x, 105, 64, 30);
	[header addSubview:play];
	UIButton *shuffle = [self borderedButton:@"Shuffle" action:@selector(shuffleTapped)];
	shuffle.frame = CGRectMake(x + 72, 105, 72, 30);
	[header addSubview:shuffle];

	_offlineButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_offlineButton.frame = CGRectMake(width - 46, 57, 36, 36);
	_offlineButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	[_offlineButton addTarget:self action:@selector(offlineTapped) forControlEvents:UIControlEventTouchUpInside];
	[header addSubview:_offlineButton];

	if (_fromEntity) {
		_addButton = [self borderedButton:@"Add to Library" action:@selector(addTapped)];
		_addButton.frame = CGRectMake(15, 151, width - 30, 32);
		_addButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
		[header addSubview:_addButton];
	}

	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(15, height - 0.5, width - 15, 0.5)];
	line.backgroundColor = [P7Theme separatorColor];
	line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[header addSubview:line];
	return header;
}

- (void)updateHeader {
	_nameLabel.text = _playlist.name;
	NSInteger duration = 0;
	for (P7Track *track in _tracks) duration += track.duration;
	if (!duration) duration = _playlist.duration;
	NSInteger count = _tracks.count ?: _playlist.trackCount;
	NSString *info = [NSString stringWithFormat:@"%@\n%@", P7TrackCountString(count), P7FormatLongDuration(duration)];
	if (_playlist.owner.length && ![_playlist.kind isEqualToString:@"playlist"] && ![_playlist.owner isEqualToString:@"Artist"] && ![_playlist.owner isEqualToString:@"Channel"]) {
		info = [NSString stringWithFormat:@"%@\n%@", _playlist.owner, info];
	}

	P7Downloads *downloads = [P7Downloads shared];
	BOOL saved = [downloads isPlaylistSaved:_playlist.playlistID];
	NSInteger offline = 0, pending = 0;
	for (P7Track *track in _tracks) {
		if ([downloads isDownloaded:track.trackID]) offline++;
		else if ([downloads isDownloading:track.trackID]) pending++;
	}
	if (saved && pending) {
		info = [info stringByAppendingFormat:@"\nDownloading %ld of %ld…", (long)MIN(offline + 1, offline + pending), (long)(offline + pending)];
	} else if (saved) {
		info = [info stringByAppendingString:@"\nAvailable offline"];
	}
	_infoLabel.text = info;
	[_offlineButton setImage:saved ? [P7Theme downloadedIcon] : [P7Theme downloadIcon] forState:UIControlStateNormal];
	_offlineButton.tintColor = [P7Theme tintColor];
	[self installFilterIfNeeded];
	[_artworkView p7_setCoverForTrackID:_playlist.coverKey ?: [_tracks.firstObject coverKey] size:240 placeholder:[P7Theme placeholderArtworkWithSize:120]];
	_artworkView.layer.cornerRadius = [_playlist.kind isEqualToString:@"artist"] ? 60 : 0;

	BOOL imported = _playlist.imported;
	[_addButton setTitle:_importing ? @"Adding…" : imported ? @"In Your Library" : @"Add to Library" forState:UIControlStateNormal];
	_addButton.enabled = !imported && !_importing && _playlist.url.length;
	_addButton.layer.borderColor = (_addButton.enabled ? [P7Theme tintColor] : [P7Theme separatorColor]).CGColor;
}

- (void)addTapped {
	if (_importing || !_playlist.url.length) return;
	_importing = YES;
	[self updateHeader];
	[[P7API shared] importURL:_playlist.url completion:^(P7Playlist *playlist, BOOL background, NSError *error) {
		self->_importing = NO;
		if (error) {
			[self updateHeader];
			[P7Alert showError:error title:@"Couldn't Add"];
			return;
		}
		if (playlist) {
			self->_playlist = playlist;
			self->_tracks = playlist.tracks;
			[self.tableView reloadData];
		}
		[self updateHeader];
	}];
}

#pragma mark - Data

- (void)reload {
	if (!_tracks.count) [self showLoading];
	void (^completion)(P7Playlist *, NSError *) = ^(P7Playlist *playlist, NSError *error) {
		[self endRefreshing];
		P7Downloads *downloads = [P7Downloads shared];
		if (error || !playlist) {
			if (!self->_tracks.count) {
				for (P7Playlist *saved in [downloads savedPlaylists]) {
					if ([saved.playlistID isEqualToString:self->_playlist.playlistID]) {
						self->_playlist = saved;
						self->_tracks = saved.tracks;
					}
				}
			}
			if (self->_tracks.count) {
				[self hideMessage];
			} else {
				[self showMessage:error.localizedDescription ?: @"Couldn't load the playlist." retry:YES];
			}
			[self updateHeader];
			[self.tableView reloadData];
			return;
		}
		self->_playlist = playlist;
		self->_tracks = playlist.tracks;
		self.title = playlist.name;
		// Saved playlists follow the server: new songs get downloaded automatically.
		if ([downloads isPlaylistSaved:playlist.playlistID]) [downloads savePlaylist:playlist];
		self->_tracks.count ? [self hideMessage] : [self showMessage:@"This playlist is empty." retry:NO];
		[self updateHeader];
		[self.tableView reloadData];
	};
	if (_fromEntity) {
		[[P7API shared] fetchCollection:_playlist.playlistID completion:completion];
	} else {
		[[P7API shared] fetchPlaylist:_playlist.playlistID completion:completion];
	}
}

- (void)trackStatesDidChange {
	[super trackStatesDidChange];
	[self updateHeader];
}

#pragma mark - Filter

- (void)installFilterIfNeeded {
	if (_filterBar || _tracks.count < 20) return;
	CGFloat width = _header.bounds.size.width;
	_filterBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, _header.bounds.size.height, width, 44)];
	_filterBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_filterBar.searchBarStyle = UISearchBarStyleMinimal;
	_filterBar.placeholder = [NSString stringWithFormat:@"Search %@", P7TrackCountString(_tracks.count)];
	_filterBar.autocorrectionType = UITextAutocorrectionTypeNo;
	_filterBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
	_filterBar.delegate = self;
	CGRect frame = _header.frame;
	frame.size.height += 44;
	_header.frame = frame;
	[_header addSubview:_filterBar];
	self.tableView.tableHeaderView = _header;   // re-set so the table picks up the new height
}

// Songs on screen: everything, or the ones matching the filter.
- (NSArray *)shownTracks {
	if (!_filter.length) return _tracks;
	if (_shownCache && _shownSource == _tracks && [_shownFilter isEqualToString:_filter]) return _shownCache;
	NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
	NSMutableArray *matches = [NSMutableArray new];
	for (P7Track *track in _tracks) {
		NSString *text = [NSString stringWithFormat:@"%@ %@ %@", track.title, track.artist, track.album ?: @""];
		if ([text rangeOfString:_filter options:options].location != NSNotFound) [matches addObject:track];
	}
	_shownCache = matches;
	_shownFilter = _filter;
	_shownSource = _tracks;
	return matches;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	_filter = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	[self.tableView reloadData];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
	[searchBar setShowsCancelButton:YES animated:YES];
	// Bring the filter up under the navigation bar while typing.
	CGFloat y = _filterBar.frame.origin.y - self.tableView.contentInset.top;
	[self.tableView setContentOffset:CGPointMake(0, y) animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
	[searchBar setShowsCancelButton:_filter.length > 0 animated:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
	searchBar.text = nil;
	_filter = nil;
	[searchBar resignFirstResponder];
	[searchBar setShowsCancelButton:NO animated:YES];
	[self.tableView reloadData];
}

#pragma mark - Actions

- (void)playTapped {
	NSArray *tracks = [self shownTracks];
	if (!tracks.count) return;
	[P7Player shared].shuffle = NO;
	[self playTracks:tracks startIndex:0];
}

- (void)shuffleTapped {
	[[P7Player shared] shuffleTracks:[self shownTracks]];
}

- (void)offlineTapped {
	P7Downloads *downloads = [P7Downloads shared];
	if (![downloads isPlaylistSaved:_playlist.playlistID]) {
		if (!_tracks.count) return;
		[downloads savePlaylist:[self playlistWithTracks]];
		return;
	}
	P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:@"Remove this playlist and its songs from offline storage?"];
	[sheet addDestructiveButton:@"Remove Download" handler:^{ [downloads removePlaylistID:self->_playlist.playlistID]; }];
	[sheet showFrom:self];
}

- (P7Playlist *)playlistWithTracks {
	if (_playlist.tracks.count) return _playlist;
	NSMutableDictionary *raw = [_playlist.raw mutableCopy];
	NSMutableArray *tracks = [NSMutableArray new];
	for (P7Track *track in _tracks) [tracks addObject:track.raw];
	raw[@"tracks"] = tracks;
	return [P7Playlist itemWithDictionary:raw];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [self shownTracks].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	NSArray *tracks = [self shownTracks];
	return [self trackCellForTrack:tracks[MIN(indexPath.row, (NSInteger)tracks.count - 1)] number:indexPath.row + 1];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSArray *tracks = [self shownTracks];
	if (indexPath.row < (NSInteger)tracks.count) [self playTracks:tracks startIndex:indexPath.row];
}

@end
