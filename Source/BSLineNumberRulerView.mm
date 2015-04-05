/*
 * MacGDBp
 * Copyright (c) 2007 - 2011, Blue Static <http://www.bluestatic.org>
 * 
 * This program is free software; you can redistribute it and/or modify it under the terms of the GNU 
 * General Public License as published by the Free Software Foundation; either version 2 of the 
 * License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without 
 * even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU 
 * General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License along with this program; if not, 
 * write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
 */

#import "BSLineNumberRulerView.h"

#include <algorithm>

#import "Breakpoint.h"
#import "BSSourceView.h"

@interface BSLineNumberRulerView (Private)
- (void)computeLineIndex;
- (NSAttributedString*)attributedStringForLineNumber:(NSUInteger)line withMarker:(BOOL)marker;
- (NSDictionary*)fontAttributes;
- (NSDictionary*)fontAttributesMarked;
- (void)drawBreakpointInRect:(NSRect)rect;
- (void)drawProgramCounterInRect:(NSRect)rect;
- (void)drawBreakpointAndProgramCounterInRect:(NSRect)rect;
- (void)drawMarkerInRect:(NSRect)rect fillColor:(NSColor*)fill;
@end

// Constants {{

// The default width of the ruler.
const CGFloat kDefaultWidth = 30.0;

// Padding between the right edge of the ruler and the line number string.
const CGFloat kRulerRightPadding = 2.5;

// Width of the arrow of the markers
const CGFloat kArrowWidth = 7.0;

// }}


@implementation BSLineNumberRulerView

- (id)initWithSourceView:(BSSourceView*)sourceView
{
  if (self = [super initWithScrollView:[sourceView scrollView]
                           orientation:NSVerticalRuler]) {
    sourceView_ = sourceView;
    [self setClientView:[[sourceView_ scrollView] documentView]];
    [self setRuleThickness:kDefaultWidth];
  }
  return self;
}

- (void)awakeFromNib
{
  [self setClientView:[[sourceView_ scrollView] documentView]];
  [self setRuleThickness:kDefaultWidth];
}

- (void)drawHashMarksAndLabelsInRect:(NSRect)rect
{
  // Draw the background color.
  [[NSColor colorWithDeviceRed:0.871 green:0.871 blue:0.871 alpha:1] set];
  [NSBezierPath fillRect:rect];

  // Draw the right stroke.
  [[NSColor grayColor] setStroke];
  [NSBezierPath strokeLineFromPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))
                            toPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];

  // Get some common elements of the source view.
  NSTextView* textView = [sourceView_ textView];
  NSLayoutManager* layoutManager = [textView layoutManager];
  NSTextContainer* textContainer = [textView textContainer];
  NSRect visibleRect = [[[self scrollView] contentView] bounds];

  // Get the visible glyph range, as NSRulerView only draws in the visible rect.
  NSRange visibleGlyphRange = [layoutManager glyphRangeForBoundingRect:visibleRect
                                                       inTextContainer:textContainer];
  NSRange characterRange = [layoutManager characterRangeForGlyphRange:visibleGlyphRange
                                                     actualGlyphRange:NULL];

  // Load any markers. The superview takes care of filtering out for just the
  // curently displayed file.
  NSSet* markers = [sourceView_ markers];

  // Go through the lines.
  const NSRange kNullRange = NSMakeRange(NSNotFound, 0);
  const CGFloat yOffset = [textView textContainerInset].height;

  const size_t lineCount = lineIndex_.size();
  std::vector<NSUInteger>::iterator element =
      std::lower_bound(lineIndex_.begin(),
                       lineIndex_.end(),
                       characterRange.location);
  for (NSUInteger line = std::distance(lineIndex_.begin(), element);
       line < lineCount; ++line) {
    NSUInteger firstCharacterIndex = lineIndex_[line];
    // Stop after iterating past the end of the visible range.
    if (firstCharacterIndex > NSMaxRange(characterRange))
      break;

    NSUInteger rectCount;
    NSRectArray frameRects = [layoutManager rectArrayForCharacterRange:NSMakeRange(firstCharacterIndex, 0)
                                          withinSelectedCharacterRange:kNullRange
                                                       inTextContainer:textContainer
                                                             rectCount:&rectCount];
    if (frameRects) {
      NSUInteger lineNumber = line + 1;
      Breakpoint* bpTest = [[[Breakpoint alloc] initWithLine:lineNumber
                                                    inFile:[sourceView_ file]] autorelease];
      BOOL isBreakpoint = [markers containsObject:bpTest];
      BOOL isMarked = (sourceView_.markedLine == lineNumber);
      
      NSAttributedString* lineNumberString =
          [self attributedStringForLineNumber:lineNumber withMarker:!(isMarked||isBreakpoint)];
      NSSize stringSize = [lineNumberString size];

      CGFloat yCoord = yOffset + NSMinY(frameRects[0]) - NSMinY(visibleRect);
      NSRect numberRect = NSMakeRect(NSWidth(rect) - stringSize.width - kRulerRightPadding - kArrowWidth,
                                   yCoord + (NSHeight(frameRects[0]) - stringSize.height) / 2.0,
                                   NSWidth(rect) - kRulerRightPadding,
                                   NSHeight(frameRects[0]));
      
      NSRect markerRect = numberRect;
      markerRect.origin.x = NSMinX(rect);

      if (isMarked && isBreakpoint) {
        [self drawBreakpointAndProgramCounterInRect:markerRect];
      } else if (isMarked) {
        [self drawProgramCounterInRect:markerRect];
      } else if (isBreakpoint) {
        [self drawBreakpointInRect:markerRect];
      }
      
      [lineNumberString drawInRect:numberRect];
    }
  }
}

- (void)performLayout
{
  [self computeLineIndex];

  // Determine the width of the ruler based on the line count.
  NSUInteger lastElement = lineIndex_.back() + 1;
  NSAttributedString* lastElementString = [self attributedStringForLineNumber:lastElement withMarker:NO];
  NSSize boundingSize = [lastElementString size];
  [self setRuleThickness:std::max(kDefaultWidth, boundingSize.width + kArrowWidth)];

  [self setNeedsDisplay:YES];
}

- (NSUInteger)lineNumberAtPoint:(NSPoint)point
{
  // Get some common elements of the source view.
  NSTextView* textView = [sourceView_ textView];
  NSLayoutManager* layoutManager = [textView layoutManager];
  NSTextContainer* textContainer = [textView textContainer];
  NSRect visibleRect = [[[self scrollView] contentView] bounds];
  point.y += NSMinY(visibleRect);  // Adjust for scroll offset.

  const CGFloat kWidth = NSWidth([self bounds]);
  const NSRange kNullRange = NSMakeRange(NSNotFound, 0);
  const size_t lineCount = lineIndex_.size();
  for (NSUInteger line = 0; line < lineCount; ++line) {
    NSUInteger firstCharacterIndex = lineIndex_[line];

    NSUInteger rectCount;
    NSRectArray frameRects =
        [layoutManager rectArrayForCharacterRange:NSMakeRange(firstCharacterIndex, 0)
                     withinSelectedCharacterRange:kNullRange
                                  inTextContainer:textContainer
                                        rectCount:&rectCount];
    for (NSUInteger i = 0; i < rectCount; ++i) {
      frameRects[i].size.width = kWidth;
      if (NSPointInRect(point, frameRects[i])) {
        return line + 1;
      }
    }
  }
  return NSNotFound;
}

- (void)mouseDown:(NSEvent*)theEvent
{
  NSPoint point = [theEvent locationInWindow];
  point = [self convertPoint:point fromView:nil];
  NSUInteger line = [self lineNumberAtPoint:point];
  if (line != NSNotFound)
    [sourceView_.delegate gutterClickedAtLine:line forFile:sourceView_.file];
}

// Private /////////////////////////////////////////////////////////////////////

/**
 * Iterates over the text storage system and computes a map of line numbers to
 * first character index for a line's frame rectangle.
 */
- (void)computeLineIndex
{
  lineIndex_.clear();

  NSString* text = [[sourceView_ textView] string];
  NSUInteger stringLength = [text length];
  NSUInteger index = 0;

  while (index < stringLength) {
    lineIndex_.push_back(index);
    index = NSMaxRange([text lineRangeForRange:NSMakeRange(index, 0)]);
  }

  NSUInteger lineEnd, contentEnd;
  [text getLineStart:NULL
                 end:&lineEnd
         contentsEnd:&contentEnd
            forRange:NSMakeRange(lineIndex_.back(), 0)];
  if (contentEnd < lineEnd)
    lineIndex_.push_back(index);
}

/**
 * Takes in a line number and returns a formatted attributed string, usable
 * for drawing.
 */
- (NSAttributedString*)attributedStringForLineNumber:(NSUInteger)line withMarker:(BOOL)marker
{
  NSString* format = [NSString stringWithFormat:@"%lu", (unsigned long)line];
  NSDictionary* attrs;
  if (marker) {
    attrs = [self fontAttributes];
  } else {
    attrs = [self fontAttributesMarked];
  }
  
  return [[[NSAttributedString alloc] initWithString:format
                                          attributes:attrs] autorelease];
}

/**
 * Returns the dictionary for an NSAttributedString with which the line numbers
 * will be drawn.
 */
- (NSDictionary*)fontAttributes
{
  NSFont* font = [NSFont fontWithName:@"Menlo" size:10.0];
  if (!font)
    font = [NSFont fontWithName:@"Monaco" size:10.0];
  return [NSDictionary dictionaryWithObjectsAndKeys:
      font, NSFontAttributeName,
      [NSColor grayColor], NSForegroundColorAttributeName,
      nil
  ];
}

/**
 * Returns the dictionary for an NSAttributedString with which the line numbers
 * will be drawn on markers.
 */
- (NSDictionary*)fontAttributesMarked
{
  NSFont* font = [NSFont fontWithName:@"Menlo" size:10.0];
  if (!font)
    font = [NSFont fontWithName:@"Monaco" size:10.0];
  return [NSDictionary dictionaryWithObjectsAndKeys:
          font, NSFontAttributeName,
          [NSColor whiteColor], NSForegroundColorAttributeName,
          nil
          ];
}

/**
 * Draws a breakpoint (a blue arrow) in the specified rectangle.
 */
- (void)drawBreakpointInRect:(NSRect)rect
{
  [self drawMarkerInRect:rect
               color:[NSColor colorWithDeviceRed:0.004 green:0.557 blue:0.851 alpha:1.0]];
}

/**
 * Draws the program counter (a green arrow) in the specified rectangle.
 */
- (void)drawProgramCounterInRect:(NSRect)rect
{
  [self drawMarkerInRect:rect
               color:[NSColor colorWithDeviceRed:0.574 green:0.687 blue:0.519 alpha:1.0]];
}

/**
 * Draws the program counter (a green arrow) in the specified rectangle.
 */
- (void)drawBreakpointAndProgramCounterInRect:(NSRect)rect
{
    NSRect blueRect = rect;
    blueRect.size.width = NSWidth(rect) - kArrowWidth;
    
    [self drawMarkerInRect:rect
                     color:[NSColor colorWithDeviceRed:0.574 green:0.687 blue:0.519 alpha:1.0]];
    [self drawMarkerInRect:blueRect
                     color:[NSColor colorWithDeviceRed:0.004 green:0.557 blue:0.851 alpha:1.0]];
}

/**
 * Draws the arrow shape in a given color.
 */
- (void)drawMarkerInRect:(NSRect)rect
               color:(NSColor*)fill
{
  [[NSGraphicsContext currentContext] saveGraphicsState];

  NSBezierPath* path = [NSBezierPath bezierPath];

  const CGFloat kPadding = 2;
  const CGFloat minX = NSMinX(rect) + kPadding;
  const CGFloat maxX = NSMaxX(rect);
  const CGFloat minY = NSMinY(rect) + kPadding;

  [path moveToPoint:NSMakePoint(minX, minY)]; // initial origin
  [path lineToPoint:NSMakePoint(maxX - kArrowWidth, minY)]; // upper right
  [path lineToPoint:NSMakePoint(maxX - kPadding, NSMidY(rect))]; // point
  [path lineToPoint:NSMakePoint(maxX - kArrowWidth, NSMaxY(rect) - kPadding)]; // lower right
  [path lineToPoint:NSMakePoint(minX, NSMaxY(rect) - kPadding)]; // lower left
  [path lineToPoint:NSMakePoint(minX, minY - 1)]; // upper left

  [fill set];
  [path fill];

  [[NSGraphicsContext currentContext] restoreGraphicsState];
}

@end
