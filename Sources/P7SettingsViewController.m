#import "P7SettingsViewController.h"
#import "P7Settings.h"
#import "P7MiniPlayer.h"
#import "P7API.h"
#import "P7Downloads.h"
#import "P7ImageCache.h"
#import "P7Blocks.h"
#import "P7Theme.h"
#import "P7AudioCache.h"
#import "P7Scrobbler.h"
#import "P7Script.h"
#import "P7Discord.h"
#import "P7DiscordLinkViewController.h"

typedef NS_ENUM(NSInteger, P7SettingsSection) {
	P7SettingsSectionSource,
	P7SettingsSectionConnection,
	P7SettingsSectionLastFM,
	P7SettingsSectionDiscord,
	P7SettingsSectionCache,
	P7SettingsSectionStorage,
	P7SettingsSectionAbout,
	P7SettingsSectionCount,
};

@interface P7SettingsViewController () <UITextFieldDelegate>
@end

@implementation P7SettingsViewController {
	UITextField *_serverField;
	UITextField *_tokenField;
	UITextField *_subsonicField;
	UITextField *_usernameField;
	UITextField *_passwordField;
	NSString *_connectionStatus;
	BOOL _testing;
	long long _downloadBytes;   // -1 until measured
	long long _imageBytes;
	BOOL _measuring;
	BOOL _measureAgain;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		self.title = @"Settings";
		self.tabBarItem.image = [P7Theme tabSettingsIcon];
		_downloadBytes = _imageBytes = -1;
	}
	return self;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	[self p7_adjustInsetsForMiniPlayer:self.tableView];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	P7Settings *settings = [P7Settings shared];
	_serverField = [self textFieldWithPlaceholder:@"http://192.168.1.10:8787"];
	_serverField.keyboardType = UIKeyboardTypeURL;
	_serverField.returnKeyType = UIReturnKeyNext;
	_serverField.text = settings.serverURL;

	_tokenField = [self textFieldWithPlaceholder:@"Optional"];
	_tokenField.secureTextEntry = YES;
	_tokenField.returnKeyType = UIReturnKeyDone;
	_tokenField.text = settings.token;

	_subsonicField = [self textFieldWithPlaceholder:@"http://192.168.1.10:4533"];
	_subsonicField.keyboardType = UIKeyboardTypeURL;
	_subsonicField.returnKeyType = UIReturnKeyNext;
	_subsonicField.text = settings.subsonicURL;

	_usernameField = [self textFieldWithPlaceholder:@"Required"];
	_usernameField.returnKeyType = UIReturnKeyNext;
	_usernameField.text = settings.subsonicUsername;

	_passwordField = [self textFieldWithPlaceholder:@"Required"];
	_passwordField.secureTextEntry = YES;
	_passwordField.returnKeyType = UIReturnKeyDone;
	_passwordField.text = settings.subsonicPassword;

	self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storageChanged) name:P7DownloadsDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storageChanged) name:P7AudioCacheDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(lastFMChanged) name:P7LastFMDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(discordChanged) name:P7DiscordDidChangeNotification object:nil];
}

- (void)lastFMChanged {
	if (self.isViewLoaded && self.view.window) {
		[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:P7SettingsSectionLastFM] withRowAnimation:UITableViewRowAnimationNone];
	}
}

- (void)discordChanged {
	if (self.isViewLoaded) [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:P7SettingsSectionDiscord] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[[P7Scrobbler shared] refreshStatus];
	[self.tableView reloadData];
	[self measureStorage];
}

- (void)storageChanged {
	if (self.isViewLoaded && self.view.window) {
		NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:P7SettingsSectionStorage];
		[sections addIndex:P7SettingsSectionCache];
		[self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
		[self measureStorage];
	}
}

// Adding up hundreds of files takes a moment on old iPhones, so it happens in the background.
- (void)measureStorage {
	if (_measuring) {
		_measureAgain = YES;
		return;
	}
	_measuring = YES;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		long long downloads = [P7Downloads shared].totalBytes;
		long long images = (long long)[[P7ImageCache shared] diskBytes];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_measuring = NO;
			BOOL changed = downloads != self->_downloadBytes || images != self->_imageBytes;
			self->_downloadBytes = downloads;
			self->_imageBytes = images;
			if (changed && self.isViewLoaded && self.view.window) {
				[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:P7SettingsSectionStorage] withRowAnimation:UITableViewRowAnimationNone];
			}
			if (self->_measureAgain) {
				self->_measureAgain = NO;
				[self measureStorage];
			}
		});
	});
}

- (NSString *)sizeText:(long long)bytes {
	return bytes < 0 ? @"" : [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (UITextField *)textFieldWithPlaceholder:(NSString *)placeholder {
	UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 190, 30)];
	field.placeholder = placeholder;
	field.textAlignment = NSTextAlignmentRight;
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	field.clearButtonMode = UITextFieldViewModeWhileEditing;
	field.textColor = [P7Theme secondaryTextColor];
	field.delegate = self;
	return field;
}

#pragma mark - Source

- (P7Backend)backend {
	return [P7Settings shared].backend;
}

// This iPhone scrobbles through a Player7 server when one is set up (see P7Scrobbler).
- (BOOL)showsLastFM {
	return [self backend] != P7BackendDevice || [P7Settings shared].serverURL.length > 0;
}

// Rows of the connection section, by backend.
- (NSArray *)connectionRows {
	switch ([self backend]) {
		case P7BackendDevice: return @[@"extractor"];
		case P7BackendServer: return @[@"server", @"token", @"test", @"youtube"];
		case P7BackendSubsonic: return @[@"subsonic", @"username", @"password", @"test"];
	}
	return @[];
}

- (void)selectBackend:(P7Backend)backend {
	if (backend == [self backend]) return;
	[self.view endEditing:YES];
	[P7Settings shared].backend = backend;
	_connectionStatus = nil;
	_testing = NO;
	[self.tableView reloadData];
	if (backend != P7BackendDevice) [self testConnection];
}

#pragma mark - Text fields

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	if (textField == _serverField) {
		[_tokenField becomeFirstResponder];
	} else if (textField == _subsonicField) {
		[_usernameField becomeFirstResponder];
	} else if (textField == _usernameField) {
		[_passwordField becomeFirstResponder];
	} else {
		[textField resignFirstResponder];
	}
	return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
	P7Settings *settings = [P7Settings shared];
	NSString *text = textField.text ?: @"";
	BOOL changed = YES;
	if (textField == _serverField && ![text isEqualToString:settings.serverURL ?: @""]) {
		settings.serverURL = text;
		textField.text = settings.serverURL;
	} else if (textField == _tokenField && ![text isEqualToString:settings.token ?: @""]) {
		settings.token = text;
	} else if (textField == _subsonicField && ![text isEqualToString:settings.subsonicURL ?: @""]) {
		settings.subsonicURL = text;
		textField.text = settings.subsonicURL;
	} else if (textField == _usernameField && ![text isEqualToString:settings.subsonicUsername ?: @""]) {
		settings.subsonicUsername = text;
	} else if (textField == _passwordField && ![text isEqualToString:settings.subsonicPassword ?: @""]) {
		settings.subsonicPassword = text;
	} else {
		changed = NO;
	}
	if (changed) [self testConnection];
}

- (void)testConnection {
	if ([self backend] == P7BackendDevice) return;
	if (![P7Settings shared].isConfigured) {
		_testing = NO;
		_connectionStatus = [self backend] == P7BackendSubsonic ? @"Enter the address and username" : @"Enter the address";
		[self reloadConnectionStatus];
		return;
	}
	_testing = YES;
	_connectionStatus = @"Connecting…";
	[self reloadConnectionStatus];
	P7Backend backend = [self backend];
	[[P7API shared] pingWithCompletion:^(NSError *error) {
		if (backend != [self backend]) return;
		self->_testing = NO;
		self->_connectionStatus = error ? error.localizedDescription : @"Connected";
		[self reloadConnectionStatus];
	}];
}

- (void)reloadConnectionStatus {
	NSUInteger row = [[self connectionRows] indexOfObject:@"test"];
	if (row == NSNotFound) return;
	NSIndexPath *statusPath = [NSIndexPath indexPathForRow:row inSection:P7SettingsSectionConnection];
	[self.tableView reloadRowsAtIndexPaths:@[statusPath] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return P7SettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
		case P7SettingsSectionSource: return 3;
		case P7SettingsSectionConnection: return [self connectionRows].count;
		case P7SettingsSectionLastFM:
			if (![self showsLastFM]) return 0;
			return [P7Scrobbler shared].connected ? 2 : 1;
		case P7SettingsSectionDiscord:
			if (![P7Discord shared].available) return 0;
			return [P7Discord shared].connected ? 2 : 1;
		case P7SettingsSectionCache: return [P7Settings shared].savePlayedSongs ? 1 : 4;
		case P7SettingsSectionStorage: return [P7Downloads shared].activeDownloadCount ? 4 : 3;
		default: return 1;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch (section) {
		case P7SettingsSectionSource: return @"Music Source";
		case P7SettingsSectionConnection: return @[@"This iPhone", @"Player7 Server", @"Subsonic Server"][[self backend]];
		case P7SettingsSectionLastFM: return [self showsLastFM] ? @"Last.fm" : nil;
		case P7SettingsSectionDiscord: return [P7Discord shared].available ? @"Discord" : nil;
		case P7SettingsSectionCache: return @"Played Songs";
		case P7SettingsSectionStorage: return @"Offline Storage";
		default: return nil;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == P7SettingsSectionConnection) {
		switch ([self backend]) {
			case P7BackendDevice: return @"Search and play YouTube Music right on this iPhone, no computer needed. Your playlists and songs are kept on the phone.";
			case P7BackendServer: return @"The address of your Player7 server, for example the IP of the computer running it on your Wi-Fi. It adds Spotify, SoundCloud and imports. YouTube plays straight from this iPhone unless YouTube via Server is on.";
			case P7BackendSubsonic: return @"Navidrome, Airsonic, Gonic or another Subsonic-compatible server. Songs it has in formats the iPhone can't play are converted to MP3 by the server.";
		}
	}
	if (section == P7SettingsSectionLastFM) {
		P7Scrobbler *scrobbler = [P7Scrobbler shared];
		if (![self showsLastFM]) return nil;
		if ([scrobbler.via isEqualToString:@"subsonic"]) return @"Plays are sent to your Subsonic server, which passes them on to Last.fm or ListenBrainz if it's set up to.";
		if (!scrobbler.configured) return @"Add lastfm_api_key and lastfm_api_secret to the server's config.json to scrobble.";
		if (!scrobbler.connected) return @"Scrobble the songs you play to your Last.fm profile.";
		NSString *text = @"A song is scrobbled once you've heard half of it, or 4 minutes. Songs played offline are sent later.";
		if (scrobbler.pendingCount) text = [text stringByAppendingFormat:@"\n%lu waiting to be sent.", (unsigned long)scrobbler.pendingCount];
		return text;
	}
	if (section == P7SettingsSectionDiscord && [P7Discord shared].available) {
		return @"Shows the song you're playing on your Discord profile, with its cover. It goes away when you pause.";
	}
	if (section == P7SettingsSectionCache) {
		return [P7Settings shared].savePlayedSongs
			? @"Every song you play (and the next one) is saved to Offline, so it plays without a connection."
			: @"Songs you play are kept in a cache that removes the oldest ones when it is full. Offline songs are never removed.";
	}
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	if (indexPath.section == P7SettingsSectionSource) {
		cell.textLabel.text = @[@"This iPhone", @"Player7 Server", @"Subsonic Server"][indexPath.row];
		cell.accessoryType = indexPath.row == [self backend] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	} else if (indexPath.section == P7SettingsSectionConnection) {
		NSString *row = [self connectionRows][indexPath.row];
		if ([row isEqualToString:@"extractor"]) {
			cell.textLabel.text = @"YouTube Extractor";
			cell.detailTextLabel.text = [P7Script shared].version ?: @"Missing";
		} else if ([row isEqualToString:@"server"] || [row isEqualToString:@"subsonic"]) {
			cell.textLabel.text = @"Address";
			cell.accessoryView = [row isEqualToString:@"server"] ? _serverField : _subsonicField;
		} else if ([row isEqualToString:@"token"]) {
			cell.textLabel.text = @"Token";
			cell.accessoryView = _tokenField;
		} else if ([row isEqualToString:@"username"]) {
			cell.textLabel.text = @"Username";
			cell.accessoryView = _usernameField;
		} else if ([row isEqualToString:@"password"]) {
			cell.textLabel.text = @"Password";
			cell.accessoryView = _passwordField;
		} else if ([row isEqualToString:@"youtube"]) {
			cell.textLabel.text = @"YouTube via Server";
			UISwitch *toggle = [UISwitch new];
			toggle.on = [P7Settings shared].youtubeOnServer;
			[toggle addTarget:self action:@selector(youtubeOnServerChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryView = toggle;
		} else {
			cell.textLabel.text = @"Test Connection";
			cell.textLabel.textColor = [P7Theme tintColor];
			cell.detailTextLabel.text = _connectionStatus;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
			if (_testing) {
				UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
				[spinner startAnimating];
				cell.accessoryView = spinner;
			}
		}
	} else if (indexPath.section == P7SettingsSectionLastFM) {
		P7Scrobbler *scrobbler = [P7Scrobbler shared];
		if (!scrobbler.configured) {
			cell.textLabel.text = @"Last.fm";
			cell.detailTextLabel.text = @"Not set up";
		} else if ([scrobbler.via isEqualToString:@"subsonic"] && indexPath.row == 0) {
			cell.textLabel.text = @"Account";
			cell.detailTextLabel.text = scrobbler.username;
		} else if (!scrobbler.connected) {
			cell.textLabel.text = @"Connect to Last.fm";
			cell.textLabel.textColor = [P7Theme tintColor];
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 0) {
			cell.textLabel.text = @"Account";
			cell.detailTextLabel.text = scrobbler.username;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else {
			cell.textLabel.text = @"Scrobble";
			UISwitch *toggle = [UISwitch new];
			toggle.on = scrobbler.enabled;
			[toggle addTarget:self action:@selector(scrobbleChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryView = toggle;
		}
	} else if (indexPath.section == P7SettingsSectionDiscord) {
		P7Discord *discord = [P7Discord shared];
		if (!discord.connected) {
			cell.textLabel.text = @"Connect Discord";
			cell.textLabel.textColor = [P7Theme tintColor];
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 0) {
			cell.textLabel.text = @"Account";
			cell.detailTextLabel.text = discord.username;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else {
			cell.textLabel.text = @"Show What I'm Playing";
			UISwitch *toggle = [UISwitch new];
			toggle.on = discord.enabled;
			[toggle addTarget:self action:@selector(discordChangedSwitch:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryView = toggle;
		}
	} else if (indexPath.section == P7SettingsSectionCache && indexPath.row == 0) {
		cell.textLabel.text = @"Save to Offline";
		UISwitch *toggle = [UISwitch new];
		toggle.on = [P7Settings shared].savePlayedSongs;
		[toggle addTarget:self action:@selector(savePlayedChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
	} else if (indexPath.section == P7SettingsSectionCache) {
		P7AudioCache *cache = [P7AudioCache shared];
		if (indexPath.row == 1) {
			cell.textLabel.text = @"Cached Songs";
			cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu · %@", (unsigned long)cache.count, [NSByteCountFormatter stringFromByteCount:(long long)cache.totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
		} else if (indexPath.row == 2) {
			cell.textLabel.text = @"Maximum Size";
			cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:(long long)cache.limitBytes countStyle:NSByteCountFormatterCountStyleFile];
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else {
			cell.textLabel.text = @"Clear Song Cache";
			cell.textLabel.textColor = [P7Theme tintColor];
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		}
	} else if (indexPath.section == P7SettingsSectionStorage) {
		P7Downloads *downloads = [P7Downloads shared];
		NSString *row = [self storageRows][indexPath.row];
		if ([row isEqualToString:@"size"]) {
			cell.textLabel.text = @"Downloaded Music";
			cell.detailTextLabel.text = [self sizeText:_downloadBytes];
		} else if ([row isEqualToString:@"cancel"]) {
			NSUInteger count = downloads.activeDownloadCount;
		cell.textLabel.text = count == 1 ? @"Cancel 1 Download" : [NSString stringWithFormat:@"Cancel %lu Downloads", (unsigned long)count];
			cell.textLabel.textColor = [P7Theme tintColor];
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if ([row isEqualToString:@"images"]) {
			cell.textLabel.text = @"Clear Image Cache";
			cell.textLabel.textColor = [P7Theme tintColor];
			cell.detailTextLabel.text = [self sizeText:_imageBytes];
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else {
			cell.textLabel.text = @"Remove All Downloads";
			cell.textLabel.textColor = [P7Theme destructiveColor];
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		}
	} else {
		NSDictionary *info = [NSBundle mainBundle].infoDictionary;
		cell.textLabel.text = @"Version";
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[self.view endEditing:YES];
	if (indexPath.section == P7SettingsSectionSource) {
		[self selectBackend:(P7Backend)indexPath.row];
	} else if (indexPath.section == P7SettingsSectionConnection && [[self connectionRows][indexPath.row] isEqualToString:@"test"]) {
		[self testConnection];
	} else if (indexPath.section == P7SettingsSectionLastFM && indexPath.row == 0) {
		P7Scrobbler *scrobbler = [P7Scrobbler shared];
		if ([scrobbler.via isEqualToString:@"subsonic"]) {
			// Nothing to connect: the Subsonic server handles Last.fm.
		} else if (scrobbler.connected) {
			P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"Scrobbling as %@", scrobbler.username]];
			[sheet addDestructiveButton:@"Disconnect Last.fm" handler:^{ [scrobbler disconnect]; }];
			[sheet showFrom:self];
		} else if (scrobbler.configured) {
			[scrobbler connectFrom:self];
		}
	} else if (indexPath.section == P7SettingsSectionDiscord && indexPath.row == 0) {
		P7Discord *discord = [P7Discord shared];
		if (!discord.connected) {
			UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[P7DiscordLinkViewController new]];
			[self presentViewController:nav animated:YES completion:nil];
		} else {
			P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"Connected as %@", discord.username]];
			[sheet addDestructiveButton:@"Disconnect Discord" handler:^{ [discord disconnect]; }];
			[sheet showFrom:self];
		}
	} else if (indexPath.section == P7SettingsSectionCache && indexPath.row == 2) {
		P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:@"Keep up to"];
		for (NSNumber *megabytes in @[@500, @1000, @2000, @4000, @8000]) {
			unsigned long long bytes = megabytes.unsignedLongLongValue * 1000 * 1000;
			[sheet addButton:[NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile] handler:^{
				[P7AudioCache shared].limitBytes = bytes;
				[self.tableView reloadData];
			}];
		}
		[sheet showFrom:self];
	} else if (indexPath.section == P7SettingsSectionCache && indexPath.row == 3) {
		[[P7AudioCache shared] clear];
		[self.tableView reloadData];
	} else if (indexPath.section == P7SettingsSectionStorage) {
		P7Downloads *downloads = [P7Downloads shared];
		NSString *row = [self storageRows][indexPath.row];
		if ([row isEqualToString:@"cancel"]) {
			[downloads cancelAll];
		} else if ([row isEqualToString:@"images"]) {
			[[P7ImageCache shared] clearAll];
			[self measureStorage];
		} else if ([row isEqualToString:@"remove"]) {
			[P7Alert confirmWithTitle:@"Remove All Downloads?" message:@"Downloaded playlists and songs will be deleted from this iPhone. Your library keeps them, so you can download them again." confirm:@"Remove" handler:^{
				for (P7Playlist *playlist in [downloads savedPlaylists]) [downloads removePlaylistID:playlist.playlistID];
				for (P7Track *track in [downloads downloadedTracks]) [downloads removeTrackID:track.trackID];
				[self.tableView reloadData];
				[self measureStorage];
			}];
		}
	}
}

- (void)scrobbleChanged:(UISwitch *)toggle {
	[P7Scrobbler shared].enabled = toggle.on;
}

- (void)discordChangedSwitch:(UISwitch *)toggle {
	[P7Discord shared].enabled = toggle.on;
}

- (void)youtubeOnServerChanged:(UISwitch *)toggle {
	[P7Settings shared].youtubeOnServer = toggle.on;
}

- (void)savePlayedChanged:(UISwitch *)toggle {
	[P7Settings shared].savePlayedSongs = toggle.on;
	[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:P7SettingsSectionCache] withRowAnimation:UITableViewRowAnimationFade];
}

- (NSArray *)storageRows {
	return [P7Downloads shared].activeDownloadCount ? @[@"size", @"cancel", @"images", @"remove"] : @[@"size", @"images", @"remove"];
}

@end
