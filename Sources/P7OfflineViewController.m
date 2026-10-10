#import "P7OfflineViewController.h"
#import "P7PlaylistsViewController.h"
#import "P7PlaylistViewController.h"
#import "P7Downloads.h"
#import "P7Player.h"
#import "P7Theme.h"

static NSString *const kPlaylistCell = @"OfflinePlaylist";

@implementation P7OfflineViewController {
	UISegmentedControl *_segments;
	NSArray *_playlists;
	NSArray *_tracks;
	UILabel *_footerLabel;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Offline";
		self.tabBarItem.image = [P7Theme tabOfflineIcon];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_segments = [[UISegmentedControl alloc] initWithItems:@[@"Playlists", @"Songs"]];
	_segments.selectedSegmentIndex = 0;
	_segments.frame = CGRectMake(0, 0, 180, 29);
	[_segments addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.titleView = _segments;
	self.navigationItem.leftBarButtonItem = self.editButtonItem;

	[self.tableView registerClass:[P7PlaylistCell class] forCellReuseIdentifier:kPlaylistCell];
	_footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
	_footerLabel.textAlignment = NSTextAlignmentCenter;
	_footerLabel.font = [UIFont systemFontOfSize:14];
	_footerLabel.textColor = [P7Theme secondaryTextColor];
	_footerLabel.numberOfLines = 2;
	self.tableView.tableFooterView = _footerLabel;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reload];
}

- (BOOL)showingPlaylists {
	return _segments.selectedSegmentIndex == 0;
}

- (void)reload {
	P7Downloads *downloads = [P7Downloads shared];
	_playlists = [downloads savedPlaylists];
	_tracks = [downloads downloadedTracks];
	self.tableView.rowHeight = [self showingPlaylists] ? 76 : [P7TrackCell rowHeight];

	NSUInteger active = downloads.activeDownloadCount;
	NSString *size = [NSByteCountFormatter stringFromByteCount:downloads.totalBytes countStyle:NSByteCountFormatterCountStyleFile];
	NSString *footer = [NSString stringWithFormat:@"%@, %@", P7TrackCountString(_tracks.count), size];
	if (active) footer = [footer stringByAppendingFormat:@"\nDownloading %lu…", (unsigned long)active];
	_footerLabel.text = _tracks.count || active ? footer : nil;

	BOOL empty = [self showingPlaylists] ? !_playlists.count : !_tracks.count;
	if (empty) {
		[self showMessage:[self showingPlaylists]
			? @"No offline playlists.\nOpen a playlist and tap the download button to keep it on this iPhone."
			: @"No downloaded songs." retry:NO];
	} else {
		[self hideMessage];
	}
	[self.tableView reloadData];
}

- (void)trackStatesDidChange {
	// Rebuild the lists when a download finishes or is removed, otherwise just refresh rows.
	if ([[P7Downloads shared] downloadedTracks].count != _tracks.count || [[P7Downloads shared] savedPlaylists].count != _playlists.count) {
		[self reload];
	} else {
		[super trackStatesDidChange];
	}
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return [self showingPlaylists] ? 1 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if ([self showingPlaylists]) return _playlists.count;
	return section == 0 ? (_tracks.count ? 1 : 0) : _tracks.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	if ([self showingPlaylists]) return 76;
	return indexPath.section == 0 ? 50 : [P7TrackCell rowHeight];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if ([self showingPlaylists]) {
		P7PlaylistCell *cell = [tableView dequeueReusableCellWithIdentifier:kPlaylistCell forIndexPath:indexPath];
		[cell configureWithPlaylist:_playlists[indexPath.row]];
		return cell;
	}
	if (indexPath.section == 0) {
		UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Shuffle"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Shuffle"];
		cell.textLabel.text = @"Shuffle";
		cell.textLabel.textColor = [P7Theme tintColor];
		cell.imageView.image = [P7Theme shuffleIcon];
		cell.imageView.tintColor = [P7Theme tintColor];
		return cell;
	}
	return [self trackCellForTrack:_tracks[indexPath.row] number:0];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if ([self showingPlaylists]) {
		[self.navigationController pushViewController:[[P7PlaylistViewController alloc] initWithPlaylist:_playlists[indexPath.row]] animated:YES];
	} else if (indexPath.section == 0) {
		[[P7Player shared] shuffleTracks:_tracks];
	} else {
		[self playTracks:_tracks startIndex:indexPath.row];
	}
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return [self showingPlaylists] || indexPath.section == 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
	return @"Remove";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) return;
	if ([self showingPlaylists]) {
		[[P7Downloads shared] removePlaylistID:[_playlists[indexPath.row] playlistID]];
	} else {
		[[P7Downloads shared] removeTrackID:[_tracks[indexPath.row] trackID]];
	}
	[self reload];
}

@end
