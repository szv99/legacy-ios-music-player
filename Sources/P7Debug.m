#import "P7Debug.h"
#import "P7API.h"
#import "P7Player.h"
#import "P7Settings.h"
#import "P7TableViewController.h"
#import "P7NowPlayingViewController.h"
#import "P7SearchViewController.h"
#import "P7AudioCache.h"
#import "P7Navigator.h"
#import <AVFoundation/AVFoundation.h>

@implementation P7Debug

+ (UIViewController *)topControllerIn:(UIWindow *)window {
	UIViewController *top = window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	if ([top isKindOfClass:[UITabBarController class]]) top = [(UITabBarController *)top selectedViewController];
	if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
	return top;
}

+ (BOOL)handleURL:(NSURL *)url window:(UIWindow *)window {
	NSString *command = url.host;
	NSString *argument = url.pathComponents.count > 1 ? url.pathComponents[1] : nil;
	UITabBarController *tabs = (UITabBarController *)window.rootViewController;
	NSLog(@"[Player7] debug command %@ %@", command, argument ?: @"");

	if ([command isEqualToString:@"screenshot"]) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			UIGraphicsBeginImageContextWithOptions(window.bounds.size, YES, 0);
			[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
			UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
			UIGraphicsEndImageContext();
			[UIImagePNGRepresentation(image) writeToFile:@"/tmp/player7-screenshot.png" atomically:YES];
			NSLog(@"[Player7] screenshot saved");
		});
	} else if ([command isEqualToString:@"server"]) {
		[P7Settings shared].serverURL = [@"http://" stringByAppendingString:argument ?: @""];
		[P7Settings shared].backend = P7BackendServer;
	} else if ([command isEqualToString:@"backend"]) {
		[P7Settings shared].backend = (P7Backend)argument.integerValue;
	} else if ([command isEqualToString:@"subsonic"]) {
		// player7://subsonic?url=…&user=…&password=…
		NSMutableDictionary *query = [NSMutableDictionary new];
		for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
			NSArray *parts = [pair componentsSeparatedByString:@"="];
			if (parts.count == 2) query[parts[0]] = [parts[1] stringByRemovingPercentEncoding] ?: @"";
		}
		P7Settings *settings = [P7Settings shared];
		settings.subsonicURL = query[@"url"];
		settings.subsonicUsername = query[@"user"];
		settings.subsonicPassword = query[@"password"];
		settings.backend = P7BackendSubsonic;
	} else if ([command isEqualToString:@"import"]) {
		// player7://import?url=<percent-encoded link>
		NSString *link = [[url.query stringByReplacingOccurrencesOfString:@"url=" withString:@""] stringByRemovingPercentEncoding];
		[[P7API shared] importURL:link completion:^(P7Playlist *playlist, BOOL background, NSError *error) {
			NSLog(@"[Player7] import %@: %@", link, error ? error.localizedDescription : [NSString stringWithFormat:@"%@ (%ld songs)", playlist.name, (long)playlist.trackCount]);
		}];
	} else if ([command isEqualToString:@"clearsongs"]) {
		[[P7AudioCache shared] clear];
	} else if ([command isEqualToString:@"token"]) {
		[P7Settings shared].token = argument;
	} else if ([command isEqualToString:@"tab"]) {
		[tabs dismissViewControllerAnimated:NO completion:nil];
		tabs.selectedIndex = argument.integerValue;
	} else if ([command isEqualToString:@"select"]) {
		UIViewController *top = [self topControllerIn:window];
		if ([top isKindOfClass:[UITableViewController class]]) {
			UITableView *table = [(UITableViewController *)top tableView];
			NSInteger row = argument.integerValue;
			NSInteger section = 0;
			while (section < table.numberOfSections && row >= [table numberOfRowsInSection:section]) {
				row -= [table numberOfRowsInSection:section];
				section++;
			}
			if (section < table.numberOfSections) {
				NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
				[table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
			}
		}
	} else if ([command isEqualToString:@"back"]) {
		UIViewController *selected = tabs.selectedViewController;
		if ([selected isKindOfClass:[UINavigationController class]]) [(UINavigationController *)selected popViewControllerAnimated:NO];
	} else if ([command isEqualToString:@"dismiss"]) {
		UIViewController *top = window.rootViewController;
		while (top.presentedViewController.presentedViewController) top = top.presentedViewController;
		[top dismissViewControllerAnimated:NO completion:nil];
	} else if ([command isEqualToString:@"nowplaying"]) {
		[tabs dismissViewControllerAnimated:NO completion:nil];
		[tabs presentViewController:[P7NowPlayingViewController new] animated:NO completion:nil];
	} else if ([command isEqualToString:@"queue"]) {
		UIViewController *top = window.rootViewController;
		while (top.presentedViewController) top = top.presentedViewController;
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[P7QueueViewController new]];
		[top presentViewController:nav animated:NO completion:nil];
	} else if ([command isEqualToString:@"search"]) {
		// player7://search/<0|1|2>/<query>
		[tabs dismissViewControllerAnimated:NO completion:nil];
		NSUInteger index = [tabs.viewControllers indexOfObjectPassingTest:^BOOL(UINavigationController *nav, NSUInteger i, BOOL *stop) {
			return [nav.viewControllers.firstObject isKindOfClass:[P7SearchViewController class]];
		}];
		if (index != NSNotFound) {
			tabs.selectedIndex = index;
			UINavigationController *nav = tabs.viewControllers[index];
			NSString *query = url.pathComponents.count > 2 ? [[url.pathComponents subarrayWithRange:NSMakeRange(2, url.pathComponents.count - 2)] componentsJoinedByString:@" "] : @"";
			[(P7SearchViewController *)nav.viewControllers.firstObject searchFor:query source:argument.integerValue];
		}
	} else if ([command isEqualToString:@"artist"] || [command isEqualToString:@"collection"]) {
		// player7://artist/<sp-ar-…|yt-ch-…>, player7://collection/<sp-al-…|yt-pl-…>
		P7Entity *entity = [P7Entity entityWithID:argument name:@"" kind:[command isEqualToString:@"artist"] ? @"artist" : @"album"];
		[P7Navigator openEntity:entity from:[self topControllerIn:window]];
	} else if ([command isEqualToString:@"tableinfo"]) {
		UIViewController *top = [self topControllerIn:window];
		if ([top isKindOfClass:[UITableViewController class]]) {
			UITableView *t = [(UITableViewController *)top tableView];
			if ([argument isEqualToString:@"reload"]) [t reloadData];
			if ([argument isEqualToString:@"layout"]) { [t setNeedsLayout]; [t layoutIfNeeded]; }
			if ([argument isEqualToString:@"header"]) { UIView *h = t.tableHeaderView; t.tableHeaderView = nil; t.tableHeaderView = h; }
			NSString *info = [NSString stringWithFormat:@"%@ bounds=%@ size=%@ offset=%@ inset=%@ header=%@ scroll=%d pan=%d tracking=%d dragging=%d decel=%d refreshing=%d gestures=%@",
				NSStringFromClass([top class]), NSStringFromCGRect(t.bounds), NSStringFromCGSize(t.contentSize), NSStringFromCGPoint(t.contentOffset),
				NSStringFromUIEdgeInsets(t.contentInset), NSStringFromCGRect(t.tableHeaderView.frame), t.scrollEnabled, t.panGestureRecognizer.enabled,
				t.tracking, t.dragging, t.decelerating, [(UITableViewController *)top refreshControl].refreshing, t.gestureRecognizers];
			[info writeToFile:@"/tmp/player7-table.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		}
	} else if ([command isEqualToString:@"artistof"]) {
		P7Track *track = [P7Player shared].currentTrack;
		if (track) [P7Navigator openArtistOfTrack:track from:[self topControllerIn:window]];
	} else if ([command isEqualToString:@"probe"]) {
		// player7://probe?url=<percent-encoded audio URL>: logs whether AVPlayer can open it, and why not
		static AVPlayer *probe;
		NSURL *audio = [NSURL URLWithString:[[url.query stringByReplacingOccurrencesOfString:@"url=" withString:@""] stringByRemovingPercentEncoding]];
		AVPlayerItem *item = [AVPlayerItem playerItemWithURL:audio];
		probe = [AVPlayer playerWithPlayerItem:item];
		probe.volume = 0;
		__block NSInteger checks = 0;
		void (^__block check)(void) = nil;
		check = ^{
			if (item.status == AVPlayerItemStatusUnknown && ++checks < 60) {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), check);
				return;
			}
			NSError *error = item.error;
			NSLog(@"[Player7] probe %@: status %ld, duration %.1f, error %@ %ld %@ %@", audio, (long)item.status, CMTimeGetSeconds(item.duration), error.domain, (long)error.code, error.userInfo, item.errorLog.events.lastObject.errorComment);
			[probe pause];
			check = nil;
		};
		[probe play];
		check();
	} else if ([command isEqualToString:@"play"]) {
		[[P7API shared] searchTracks:nil completion:^(NSArray *tracks, NSError *error) {
			if (tracks.count) [[P7Player shared] playTracks:tracks startIndex:0];
		}];
	} else {
		return NO;
	}
	return YES;
}

@end
