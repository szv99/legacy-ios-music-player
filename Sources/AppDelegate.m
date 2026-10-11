#import "AppDelegate.h"
#import "P7PlaylistsViewController.h"
#import "P7SongsViewController.h"
#import "P7SearchViewController.h"
#import "P7OfflineViewController.h"
#import "P7SettingsViewController.h"
#import "P7Player.h"
#import "P7Downloads.h"
#import "P7Settings.h"
#import "P7Theme.h"
#import "P7Debug.h"
#import "P7MiniPlayer.h"
#import "P7Scrobbler.h"
#import "P7LockQueue.h"
#import "P7LocalServer.h"
#import "P7LocalLibrary.h"
#import "P7Script.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	NSLog(@"[Player7] launched on iOS %@", [UIDevice currentDevice].systemVersion);
	[P7Theme apply];
	[[P7Player shared] setUp];
	[P7Downloads shared];
	[[P7Scrobbler shared] start];
	[P7LockQueue start];

	NSMutableArray *tabs = [NSMutableArray new];
	for (UIViewController *root in @[[P7PlaylistsViewController new], [P7SongsViewController new], [P7SearchViewController new], [P7OfflineViewController new], [P7SettingsViewController new]]) {
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
		nav.tabBarItem = root.tabBarItem;
		[tabs addObject:nav];
	}
	UITabBarController *tabBar = [UITabBarController new];
	tabBar.viewControllers = tabs;
	P7Settings *settings = [P7Settings shared];
	if (!settings.isConfigured) {
		tabBar.selectedIndex = tabs.count - 1;
	} else if (settings.backend == P7BackendDevice && ![P7LocalLibrary shared].playlists.count) {
		tabBar.selectedIndex = 2;   // a fresh install starts in Search
	}
	if (settings.backend != P7BackendSubsonic) [[P7Script shared] checkForUpdate];

	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	self.window.tintColor = [P7Theme tintColor];
	self.window.backgroundColor = [UIColor whiteColor];
	self.window.rootViewController = tabBar;
	[self.window makeKeyAndVisible];
	[P7MiniPlayer attachToTabBarController:tabBar];
	[application setStatusBarStyle:UIStatusBarStyleDefault];
	return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	[[P7LocalServer shared] restartIfNeeded];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	[[P7Player shared] saveState];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	[[P7Player shared] saveState];
}

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)())completionHandler {
	[[P7Downloads shared] handleEventsForBackgroundURLSession:identifier completionHandler:completionHandler];
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
#ifdef DEBUG
	return [P7Debug handleURL:url window:self.window];
#else
	// The player7:// dev hooks could change the server from any web page; release builds ignore them.
	return NO;
#endif
}

@end
