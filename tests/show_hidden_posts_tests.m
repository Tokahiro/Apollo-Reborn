#import <Foundation/Foundation.h>
#import "ApolloShowHiddenPosts.h"

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static void ExpectName(NSString *path, NSString *expected) {
    NSString *name = ApolloShowHiddenSubredditForListingPath(path);
    CHECK((name == nil && expected == nil) || [name isEqualToString:expected],
          @"%@ -> %@, expected %@", path, name ?: @"nil", expected ?: @"nil");
}

static void TestSubredditListings(void) {
    ExpectName(@"r/apple", @"apple");
    ExpectName(@"r/apple.json", @"apple");
    ExpectName(@"/r/apple/hot.json", @"apple");
    ExpectName(@"r/Apple/Top.json", @"apple");
    for (NSString *sort in @[ @"hot", @"new", @"rising", @"top", @"controversial", @"best", @"gilded" ]) {
        ExpectName([NSString stringWithFormat:@"r/apple/%@.json", sort], @"apple");
    }
    ExpectName(@"r/allergies/hot.json", @"allergies");
    ExpectName(@"r/randomthoughts/new.json", @"randomthoughts");
    ExpectName(@"r/popularopinion/new.json", @"popularopinion");
}

static void TestOtherFeeds(void) {
    ExpectName(nil, nil);
    ExpectName(@"", nil);
    ExpectName(@"hot.json", nil);
    ExpectName(@"best.json", nil);
    ExpectName(@"r/all/best.json", nil);
    ExpectName(@"r/All/hot.json", nil);
    ExpectName(@"r/all-funny-pics/hot.json", nil);
    ExpectName(@"r/popular/hot.json", nil);
    ExpectName(@"r/mod/new.json", nil);
    ExpectName(@"r/friends/new.json", nil);
    ExpectName(@"r/random/hot.json", nil);
    ExpectName(@"r/RandNSFW/hot.json", nil);
    ExpectName(@"r/apple+android/hot.json", nil);
    ExpectName(@"user/someone/m/tech/hot.json", nil);
    ExpectName(@"r/apple/search.json", nil);
    ExpectName(@"r/apple/comments/abc123.json", nil);
    ExpectName(@"r/apple/about/modqueue.json", nil);
    ExpectName(@"r/apple/hot.xml", nil);
    ExpectName(@"r//hot.json", nil);
}

static void TestParameters(void) {
    NSDictionary *merged = ApolloShowHiddenListingParameters(@{ @"limit": @"25", @"show": @"x" });
    CHECK([merged[@"show"] isEqualToString:@"all"], @"show is all");
    CHECK([merged[@"limit"] isEqualToString:@"25"], @"other parameters kept");
    CHECK([ApolloShowHiddenListingParameters(nil) isEqualToDictionary:@{ @"show": @"all" }], @"nil parameters");
    CHECK([ApolloShowHiddenListingParameters((NSDictionary *)@"bad") isEqualToDictionary:@{ @"show": @"all" }], @"non-dictionary parameters");
}

static void TestChoices(void) {
    NSString *suite = @"apollo.show-hidden-posts-tests";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    ApolloShowHiddenClearChoices(defaults);

    CHECK(ApolloShowHiddenChoiceForSubreddit(@"apple", YES, defaults) == nil, @"no choice at first");

    // Not remembered: this launch only, nothing saved.
    ApolloShowHiddenSetChoiceForSubreddit(@"Apple", YES, NO, NO, defaults);
    CHECK([ApolloShowHiddenChoiceForSubreddit(@"apple", NO, defaults) isEqual:@YES], @"session choice, any case");
    CHECK(ApolloShowHiddenSavedChoiceCount(defaults) == 0, @"session choice is not saved");

    // A choice equal to the setting is removed.
    ApolloShowHiddenSetChoiceForSubreddit(@"apple", NO, NO, NO, defaults);
    CHECK(ApolloShowHiddenChoiceForSubreddit(@"apple", YES, defaults) == nil, @"choice equal to the setting is removed");

    // Remembered: saved, and read back after this launch's choices are gone.
    ApolloShowHiddenSetChoiceForSubreddit(@"swift", YES, NO, YES, defaults);
    CHECK(ApolloShowHiddenSavedChoiceCount(defaults) == 1, @"remembered choice is saved");
    ApolloShowHiddenSetChoiceForSubreddit(@"ios", NO, YES, YES, defaults);
    CHECK([[defaults dictionaryForKey:@"ShowHiddenPostsSubredditChoices"][@"ios"] isEqual:@NO], @"saved hide choice");
    ApolloShowHiddenClearChoices(defaults);
    [defaults setObject:@{ @"swift": @YES } forKey:@"ShowHiddenPostsSubredditChoices"];
    CHECK([ApolloShowHiddenChoiceForSubreddit(@"swift", YES, defaults) isEqual:@YES], @"saved choice applies after a restart");
    CHECK(ApolloShowHiddenChoiceForSubreddit(@"swift", NO, defaults) == nil, @"saved choice ignored while remembering is off");

    // Not remembered: a saved choice is kept for when remembering is turned on again.
    ApolloShowHiddenSetChoiceForSubreddit(@"swift", NO, NO, NO, defaults);
    CHECK(ApolloShowHiddenSavedChoiceCount(defaults) == 1, @"saved choice kept by a session change");

    ApolloShowHiddenClearChoices(defaults);
    CHECK(ApolloShowHiddenSavedChoiceCount(defaults) == 0, @"reset clears saved choices");
    CHECK(ApolloShowHiddenChoiceForSubreddit(@"swift", YES, defaults) == nil, @"reset clears every choice");
    [defaults removePersistentDomainForName:suite];
}

int main(void) {
    @autoreleasepool {
        TestSubredditListings();
        TestOtherFeeds();
        TestParameters();
        TestChoices();
    }
    if (sFailures > 0) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("show hidden posts tests passed\n");
    return 0;
}
