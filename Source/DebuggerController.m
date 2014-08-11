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

#import "DebuggerController.h"

#import "AppDelegate.h"
#import "BSSourceView.h"
#import "BreakpointManager.h"
#import "EvalController.h"
#import "NSXMLElementAdditions.h"

@interface DebuggerController (Private)
- (void)updateSourceViewer;
- (void)updateStackViewer;
- (void)expandVariables;
@end

@implementation DebuggerController

@synthesize connection, sourceViewer, inspector;

/**
 * Initializes the window controller and sets the connection using preference
 * values
 */
- (id)init
{
  if (self = [super initWithWindowNibName:@"Debugger"])
  {
    stackController = [[StackController alloc] init];
    pendingProperties_ = [[NSMutableDictionary alloc] init];

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

    connection = [[DebuggerBackEnd alloc] initWithPort:[defaults integerForKey:@"Port"]];
    connection.delegate = self;
    expandedVariables = [[NSMutableSet alloc] init];
    [[self window] makeKeyAndOrderFront:nil];
    [[self window] setDelegate:self];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"InspectorWindowVisible"])
      [inspector orderFront:self];
  }
  return self;
}

/**
 * Dealloc
 */
- (void)dealloc
{
  [connection release];
  [expandedVariables release];
  [stackController release];
  [pendingProperties_ release];
  [super dealloc];
}

/**
 * Before the display get's comfortable, set up the NSTextView to scroll horizontally
 */
- (void)awakeFromNib
{
  [[self window] setExcludedFromWindowsMenu:YES];
  [[self window] setTitle:[NSString stringWithFormat:@"MacGDBp @ %d", [connection port]]];
  [sourceViewer setDelegate:self];
  [stackArrayController setSortDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"index" ascending:YES] autorelease]]];
  self.connection.attached = [attachedCheckbox_ state] == NSOnState;
}

/**
 * Validates the menu items for the "Debugger" menu
 */
- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem
{
  SEL action = [anItem action];
  
  if (action == @selector(stepOut:)) {
    return ([connection isConnected] && [stackController.stack count] > 1);
  } else if (action == @selector(stepIn:) ||
             action == @selector(stepOver:) ||
             action == @selector(run:) ||
             action == @selector(stop:) ||
             action == @selector(showEvalWindow:)) {
    return [connection isConnected];
  }
  return [[self window] validateUserInterfaceItem:anItem];
}

/**
 * Shows the inspector window
 */
- (IBAction)showInspectorWindow:(id)sender
{
  if (![inspector isVisible])
    [inspector makeKeyAndOrderFront:sender];
  else
    [inspector orderOut:sender];
}

/**
 * Runs the eval window sheet.
 */
- (IBAction)showEvalWindow:(id)sender
{
  // The |controller| will release itself on close.
  EvalController* controller = [[EvalController alloc] initWithBackEnd:connection];
  [controller runModalForWindow:[self window]];
}

/**
 * Resets all the displays to be empty
 */
- (void)resetDisplays
{
  [variablesTreeController setContent:nil];
  [stackController.stack removeAllObjects];
  [stackArrayController rearrangeObjects];
  [[sourceViewer textView] setString:@""];
  sourceViewer.file = nil;
}

/**
 * Sets the status to be "Error" and then displays the error message
 */
- (void)setError:(NSString*)anError
{
  [errormsg setStringValue:anError];
  [errormsg setHidden:NO];
}

/**
 * Handles a GDBpConnection error
 */
- (void)errorEncountered:(NSString*)error
{
  [self setError:error];
}

/**
 * Delegate function for GDBpConnection for when the debugger connects.
 */
- (void)debuggerConnected
{
  [errormsg setHidden:YES];
  if (!self.connection.attached)
    return;
    
  [stackController.stack removeAllObjects];
  [sourceViewer setFile:nil];
    
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BreakOnFirstLine"])
    [self stepIn:self];
}

/**
 * Called once the debugger disconnects.
 */
- (void)debuggerDisconnected
{
  // Invalidate the marked line so we don't look like we're still running.
  sourceViewer.markedLine = -1;
  [sourceViewer setNeedsDisplay:YES];
}

/**
 * Forwards the message to run script execution to the connection
 */
- (IBAction)run:(id)sender
{
  [connection run];
}

- (IBAction)attachedToggled:(id)sender
{
  connection.attached = [sender state] == NSOnState;
}

/**
 * Forwards the message to "step in" to the connection
 */
- (IBAction)stepIn:(id)sender
{
  if ([[variablesTreeController selectedObjects] count] > 0)
    selectedVariable = [[variablesTreeController selectedObjects] objectAtIndex:0];
  
  [connection stepIn];
}

/**
 * Forwards the message to "step out" to the connection
 */
- (IBAction)stepOut:(id)sender
{
  if ([[variablesTreeController selectedObjects] count] > 0)
    selectedVariable = [[variablesTreeController selectedObjects] objectAtIndex:0];
  
  [connection stepOut];
}

/**
 * Forwards the message to "step over" to the connection
 */
- (IBAction)stepOver:(id)sender
{
  if ([[variablesTreeController selectedObjects] count] > 0)
    selectedVariable = [[variablesTreeController selectedObjects] objectAtIndex:0];
  
  [connection stepOver];
}

/**
 * Forwards the detach/"stop" message to the back end.
 */
- (IBAction)stop:(id)sender
{
  [connection stop];
}

- (void)fetchChildProperties:(VariableNode*)node
{
  NSArray* selection = [stackArrayController selectedObjects];
  if (![selection count])
    return;
  assert([selection count] == 1);
  NSInteger depth = [[selection objectAtIndex:0] index];
  NSInteger txn = [connection getChildrenOfProperty:node atDepth:depth];
  [pendingProperties_ setObject:node forKey:[NSNumber numberWithInt:txn]];
}

/**
 * NSTableView delegate method that informs the controller that the stack selection did change and that
 * we should update the source viewer
 */
- (void)tableViewSelectionDidChange:(NSNotification*)notif
{
  [self updateSourceViewer];
  // TODO: This is very, very hacky because it's nondeterministic. The issue
  // is that calling |-[NSOutlineView expandItem:]| while the table is still
  // doing its redraw will translate to a no-op. Instead, we need to restructure
  // this controller so that when everything has been laid out we call
  // |-expandVariables|; but NSOutlineView doesn't have a |-didFinishDoingCrap:|
  // method. The other issue is that we need to call this method from
  // selectionDidChange but ONLY when it was the result of a user-initiated
  // action and not the stack viewer updating causing a selection change.
  // If it happens in the latter, then we run into the same issue that causes
  // this to no-op.
  [self performSelector:@selector(expandVariables) withObject:nil afterDelay:0.05];
}

/**
 * Called whenver an item is expanded. This allows us to determine if we need to fetch deeper
 */
- (void)outlineViewItemDidExpand:(NSNotification*)notif
{
  NSTreeNode* node = [[notif userInfo] objectForKey:@"NSObject"];
  [expandedVariables addObject:[[node representedObject] fullName]];
}

/**
 * Called when an item was collapsed. This allows us to remove it from the list of expanded items
 */
- (void)outlineViewItemDidCollapse:(NSNotification*)notif
{
  [expandedVariables removeObject:[[[[notif userInfo] objectForKey:@"NSObject"] representedObject] fullName]];
}

#pragma mark Private

/**
 * Does the actual updating of the source viewer by reading in the file
 */
- (void)updateSourceViewer
{
  NSArray* selection = [stackArrayController selectedObjects];
  if (!selection || [selection count] < 1)
    return;
  if ([selection count] > 1)
    NSLog(@"INVALID SELECTION");
  StackFrame* frame = [selection objectAtIndex:0];

  if (!frame.loaded) {
    [connection loadStackFrame:frame];
    return;
  }

  // Get the filename.
  NSString* filename = [[NSURL URLWithString:frame.filename] path];
  if ([filename isEqualToString:@""])
    return;
  
  // Replace the source if necessary.
  if (frame.source && ![sourceViewer.file isEqualToString:filename])
  {
    [sourceViewer setString:frame.source asFile:filename];
    
    NSSet* breakpoints = [NSSet setWithArray:[[BreakpointManager sharedManager] breakpointsForFile:filename]];
    [sourceViewer setMarkers:breakpoints];
  }
  
  [sourceViewer setMarkedLine:frame.lineNumber];
  [sourceViewer scrollToLine:frame.lineNumber];
  
  [[sourceViewer textView] display];
}

/**
 * Does some house keeping to the stack viewer
 */
- (void)updateStackViewer
{
  [stackArrayController rearrangeObjects];
  [stackArrayController setSelectionIndex:0];
}

/**
 * Expands the variables based on the stored set
 */
- (void)expandVariables
{
  NSString* selection = [selectedVariable fullName];

  for (NSInteger i = 0; i < [variablesOutlineView numberOfRows]; i++) {
    NSTreeNode* node = [variablesOutlineView itemAtRow:i];
    NSString* fullName = [[node representedObject] fullName];
    
    // see if it needs expanding
    if ([expandedVariables containsObject:fullName])
      [variablesOutlineView expandItem:node];
    
    // select it if we had it selected before
    if ([fullName isEqualToString:selection])
      [variablesTreeController setSelectionIndexPath:[node indexPath]];
  }
}

#pragma mark BSSourceView Delegate

/**
 * The gutter was clicked, which indicates that a breakpoint needs to be changed
 */
- (void)gutterClickedAtLine:(int)line forFile:(NSString*)file
{
  BreakpointManager* mngr = [BreakpointManager sharedManager];
  
  if ([mngr hasBreakpointAt:line inFile:file])
  {
    [mngr removeBreakpointAt:line inFile:file];
  }
  else
  {
    Breakpoint* bp = [[Breakpoint alloc] initWithLine:line inFile:file];
    [mngr addBreakpoint:bp];
    [bp release];
  }
  
  [sourceViewer setMarkers:[NSSet setWithArray:[mngr breakpointsForFile:file]]];
  [sourceViewer setNeedsDisplay:YES];
}

#pragma mark GDBpConnectionDelegate

- (void)clobberStack
{
  aboutToClobber_ = YES;
  [pendingProperties_ removeAllObjects];
}

- (void)newStackFrame:(StackFrame*)frame
{
  if (aboutToClobber_)
  {
    [stackController.stack removeAllObjects];
    aboutToClobber_ = NO;
  }
  [stackController push:frame];
  [self updateStackViewer];
  [self updateSourceViewer];
}

- (void)sourceUpdated:(StackFrame*)frame
{
  [self updateSourceViewer];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ActivateOnBreak"]) {
        [NSApp activateIgnoringOtherApps:YES];
        [[self window] makeKeyAndOrderFront:self];
    }
}

- (void)receivedProperties:(NSArray*)properties forTransaction:(NSInteger)transaction
{
  NSNumber* key = [NSNumber numberWithInt:transaction];
  VariableNode* node = [pendingProperties_ objectForKey:key];
  if (node) {
    [node setChildrenFromXMLChildren:properties];
    [variablesTreeController rearrangeObjects];
    [pendingProperties_ removeObjectForKey:key];
  }
}

- (void)scriptWasEvaluatedWithResult:(NSString*)result
{
  [EvalController scriptWasEvaluatedWithResult:result];
}

@end
