#import "P7PlaylistsViewController.h"
#import "P7PlaylistViewController.h"
#import "P7API.h"
#import "P7Downloads.h"
#import "P7ImageCache.h"
#import "P7Settings.h"
#import "P7Blocks.h"
#import "P7Theme.h"

static NSString *const kPlaylistCell = @"P7PlaylistCell";

@implementation P7PlaylistCell {
	UIImageView *_stateView;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
		self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		self.textLabel.font = [UIFont systemFontOfSize:17];
		self.detailTextLabel.font = [UIFont systemFontOfSize:12];
		self.detailTextLabel.textColor = [P7Theme secondaryTextColor];
		self.imageView.contentMode = UIViewContentModeScaleAspectFill;
		self.imageView.clipsToBounds = YES;
		_stateView = [[UIImageView alloc] initWithImage:[P7Theme downloadedIcon]];
		_stateView.tintColor = [P7Theme secondaryTextColor];
		[self.contentView addSubview:_stateView];
		self.separatorInset = UIEdgeInsetsMake(0, 83, 0, 0);
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat height = self.contentView.bounds.size.height;
	self.imageView.frame = CGRectMake(15, (height - 60) / 2, 60, 60);
	CGFloat x = 83;
	CGFloat width = self.contentView.bounds.size.width - x - 8;
	self.textLabel.frame = CGRectMake(x, 18, width, 22);
	CGFloat detailX = x;
	if (!_stateView.hidden) {
		_stateView.frame = CGRectMake(x, 45, 12, 12);
		detailX += 16;
	}
	self.detailTextLabel.frame = CGRectMake(detailX, 43, width - (detailX - x), 16);
}

- (void)configureWithPlaylist:(P7Playlist *)playlist {
	self.textLabel.text = playlist.name;
	NSDictionary *sources = @{@"spotify": @"Spotify", @"youtube": @"YouTube", @"soundcloud": @"SoundCloud"};
	NSString *source = sources[playlist.source];
	NSString *count = P7TrackCountString(playlist.trackCount);
	NSString *kind = [playlist.kind isEqualToString:@"artist"] ? @"Artist" : [playlist.kind isEqualToString:@"album"] ? @"Album" : nil;
	if (kind) count = [NSString stringWithFormat:@"%@ · %@", kind, count];
	self.detailTextLabel.text = source ? [NSString stringWithFormat:@"%@ · %@", count, source] : count;
	self.imageView.layer.cornerRadius = kind == nil || [kind isEqualToString:@"Album"] ? 0 : 30;
	_stateView.hidden = ![[P7Downloads shared] isPlaylistSaved:playlist.playlistID];
	[self.imageView p7_setCoverForTrackID:playlist.coverKey size:120 placeholder:[P7Theme placeholderArtworkWithSize:60]];
	[self setNeedsLayout];
}

@end

@implementation P7PlaylistsViewController {
	NSArray *_playlists;
	BOOL _offline;
	BOOL _importing;
	NSTimer *_statusTimer;
	UILabel *_statusLabel;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Playlists";
		self.tabBarItem.image = [P7Theme tabPlaylistsIcon];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 76;
	[self.tableView registerClass:[P7PlaylistCell class] forCellReuseIdentifier:kPlaylistCell];
	[self updateImportButton];
	[self enablePullToRefresh];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:P7SettingsDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadQuietly) name:P7LibraryDidChangeNotification object:nil];

	_playlists = [P7Playlist itemsWithArray:[NSArray arrayWithContentsOfFile:[self cachePath]]];
	if (_playlists.count) [self.tableView reloadData];
	[self reload];
	[self pollImportStatus];
}

- (NSString *)cachePath {
	NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
	return [caches stringByAppendingPathComponent:@"playlists.plist"];
}

- (void)settingsChanged {
	[self updateImportButton];
	[self reload];
}

// Subsonic playlists are made on the server; there is nothing to import from a link.
- (void)updateImportButton {
	if (_importing) return;
	BOOL canImport = [P7Settings shared].backend != P7BackendSubsonic;
	self.navigationItem.leftBarButtonItem = canImport ? [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(importTapped)] : nil;
}

- (void)reload {
	if (![P7Settings shared].isConfigured) {
		[self endRefreshing];
		[self showMessage:@"Add your server address in Settings to see your playlists." retry:NO];
		return;
	}
	if (!_playlists.count) [self showLoading];
	[[P7API shared] fetchPlaylistsWithCompletion:^(NSArray *playlists, NSError *error) {
		[self endRefreshing];
		if (error) {
			NSArray *saved = [[P7Downloads shared] savedPlaylists];
			if (saved.count) {
				self->_offline = YES;
				self->_playlists = saved;
				[self hideMessage];
				[self.tableView reloadData];
			} else if (!self->_playlists.count) {
				[self showMessage:[NSString stringWithFormat:@"Can't reach the server.\n%@", error.localizedDescription] retry:YES];
			}
			return;
		}
		self->_offline = NO;
		self->_playlists = playlists;
		NSMutableArray *raw = [NSMutableArray new];
		for (P7Playlist *playlist in playlists) [raw addObject:playlist.raw];
		[raw writeToFile:[self cachePath] atomically:YES];
		if (playlists.count) {
			[self hideMessage];
		} else {
			NSString *message = @[@"No playlists yet.\nTap + to import one from YouTube, or find music in Search.",
				@"No playlists yet.\nTap + to import one from Spotify or YouTube.",
				@"No playlists yet.\nMake playlists or star albums and artists on your server."][[P7Settings shared].backend];
			[self showMessage:message retry:NO];
		}
		[self.tableView reloadData];
	}];
}

- (void)trackStatesDidChange {
	for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
		P7PlaylistCell *cell = (P7PlaylistCell *)[self.tableView cellForRowAtIndexPath:indexPath];
		if (indexPath.row < (NSInteger)_playlists.count) [cell configureWithPlaylist:_playlists[indexPath.row]];
	}
}

#pragma mark - Import

- (NSString *)deleteMessageFor:(P7Playlist *)playlist {
	switch ([P7Settings shared].backend) {
		case P7BackendDevice: return @"The playlist is removed from this iPhone's library. Songs saved offline stay.";
		case P7BackendSubsonic:
			return [playlist.playlistID hasPrefix:@"ss-pl-"]
				? @"The playlist is deleted from your Subsonic server for good. Songs saved offline stay on this iPhone."
				: @"It is unstarred on your Subsonic server. Songs saved offline stay on this iPhone.";
		default: return @"The playlist is removed from your server. Songs saved offline stay on this iPhone.";
	}
}

- (void)importTapped {
	if (_importing) return;
	BOOL onServer = [P7Settings shared].backend == P7BackendServer;
	NSString *message = onServer
		? @"A Spotify, YouTube or SoundCloud link: playlist, album, artist, channel or profile (soundcloud.com/name/likes for liked songs)."
		: @"A YouTube or YouTube Music link: playlist, album, channel or song.";
	NSString *placeholder = onServer ? @"https://open.spotify.com/playlist/…" : @"https://music.youtube.com/playlist?list=…";
	P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:@"Add Playlists"];
	[sheet addButton:@"Import from Link…" handler:^{
		[P7Alert promptWithTitle:@"Import from Link" message:message placeholder:placeholder confirm:@"Import" handler:^(NSString *text) {
			NSString *url = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (url.length) [self importURL:url];
		}];
	}];
	if (onServer) {
		[sheet addButton:@"Import YouTube Music Library" handler:^{
			[self importURL:@"ytmusic:library"];
		}];
	}
	[sheet showFrom:self];
}

- (void)setImporting:(BOOL)importing {
	_importing = importing;
	[UIApplication sharedApplication].networkActivityIndicatorVisible = importing;
	if (importing) {
		UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
		[spinner startAnimating];
		self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
	} else {
		[self updateImportButton];
	}
}

- (void)importURL:(NSString *)url {
	[self setImporting:YES];
	[[P7API shared] importURL:url completion:^(P7Playlist *playlist, BOOL background, NSError *error) {
		[self setImporting:NO];
		if (error) {
			[P7Alert showError:error title:@"Import Failed"];
			return;
		}
		if (background) {
			[self pollImportStatus];
			return;
		}
		[self reload];
		if (playlist) [self.navigationController pushViewController:[[P7PlaylistViewController alloc] initWithPlaylist:playlist] animated:YES];
	}];
}

// Profiles and the YouTube Music library import on the server in the background;
// show progress above the list until it finishes.
- (void)pollImportStatus {
	[_statusTimer invalidate];
	_statusTimer = nil;
	if (![P7Settings shared].isConfigured) return;
	[[P7API shared] fetchImportStatusWithCompletion:^(NSDictionary *status, NSError *error) {
		BOOL running = [status[@"running"] boolValue];
		if (running) {
			NSInteger done = [status[@"done"] integerValue], total = [status[@"total"] integerValue];
			NSString *text = total ? [NSString stringWithFormat:@"Importing playlists… %ld of %ld", (long)done, (long)total] : @"Importing playlists…";
			[self showStatus:text];
			[self reloadQuietly];
			self->_statusTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(pollImportStatus) userInfo:nil repeats:NO];
		} else if (self.tableView.tableHeaderView) {
			[self showStatus:nil];
			[self reload];
		}
	}];
}

- (void)showStatus:(NSString *)text {
	if (!text) {
		self.tableView.tableHeaderView = nil;
		return;
	}
	if (!_statusLabel) {
		_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 34)];
		_statusLabel.textAlignment = NSTextAlignmentCenter;
		_statusLabel.font = [UIFont systemFontOfSize:13];
		_statusLabel.textColor = [P7Theme secondaryTextColor];
		_statusLabel.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1];
	}
	_statusLabel.text = text;
	if (self.tableView.tableHeaderView != _statusLabel) self.tableView.tableHeaderView = _statusLabel;
}

- (void)reloadQuietly {
	[[P7API shared] fetchPlaylistsWithCompletion:^(NSArray *playlists, NSError *error) {
		if (error || [[playlists valueForKey:@"raw"] isEqualToArray:[self->_playlists valueForKey:@"raw"]]) return;
		self->_playlists = playlists;
		[self hideMessage];
		[self.tableView reloadData];
	}];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _playlists.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return _offline && _playlists.count ? @"Offline – showing saved playlists" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	P7PlaylistCell *cell = [tableView dequeueReusableCellWithIdentifier:kPlaylistCell forIndexPath:indexPath];
	[cell configureWithPlaylist:_playlists[indexPath.row]];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	P7Playlist *playlist = _playlists[indexPath.row];
	[self.navigationController pushViewController:[[P7PlaylistViewController alloc] initWithPlaylist:playlist] animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return !_offline;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	P7Playlist *playlist = _playlists[indexPath.row];
	[P7Alert confirmWithTitle:[NSString stringWithFormat:@"Delete “%@”?", playlist.name] message:[self deleteMessageFor:playlist] confirm:@"Delete" handler:^{
		[[P7API shared] deletePlaylist:playlist.playlistID completion:^(NSError *error) {
			if (error) [P7Alert showError:error title:@"Couldn't Delete"];
			[self reload];
		}];
	}];
	[tableView setEditing:NO animated:YES];
}

@end
