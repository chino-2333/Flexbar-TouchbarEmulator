#import "../src/TouchBarHiddenPlacement.h"
#include <assert.h>
static void check(NSArray<NSValue *> *screens) {
    NSRect host = TouchBarHiddenEdgeFrame(screens, NSMakeSize(1095,40));
    CGFloat overlap = 0;
    for (NSValue *v in screens) {
        NSRect intersection = NSIntersectionRect(host,v.rectValue);
        if (!NSIsEmptyRect(intersection)) {
            assert(intersection.size.width <= 1.0);
            overlap += intersection.size.width * intersection.size.height;
        }
    }
    assert(overlap >= 40.0);
    assert(host.size.width == 1095 && host.size.height == 40);
}
#define R(x,y,w,h) [NSValue valueWithRect:NSMakeRect(x,y,w,h)]
int main(void) { @autoreleasepool {
    check(@[R(0,0,1920,1080)]);
    check(@[R(0,0,1920,1080),R(-2560,-400,2560,1440)]);
    check(@[R(0,0,1920,1080),R(0,1080,1280,800)]);
    check(@[R(0,0,1920,1080),R(-1200,-900,1200,900),R(-1200,0,1200,900)]);
    check(@[R(0,0,1920,1080),R(0,0,1920,1080)]);
    puts("PASS: single, left, stacked, staggered and mirrored screen placement has only one-point edge overlap.");
} }
