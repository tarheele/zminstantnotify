#!/usr/bin/perl
#
# ==========================================================================
#
# THIS SCRIPT IS CALLED BY zminstantnotify.pl (if it is installed correctly and running)
#
# ZoneMinder Instant Notification System
#
# tl;dr - Look for "ADD YOUR STUFF HERE" for code you might want to hack
#
# I have been using ZM for about 15 years and I am thankful to those who have 
# contributed.  It is a very cool and fun security addition to my home. 
#
# Be kind, this is my first substantial perl script, so it will surely make perl junkies cringe.
#
# This user action script is called by zminstantnotify.pl, which is the the other script in this package (at this time 
# these are NOT provided by zoneminder).  Look at that script for the overview. 
#
# This user action script is called for each new event detected by zoneminder.  Do whatever you want here,
# it is your script.  
#
# This script receives as parameters the current event information as well as a persistent context.  The persistent context
# allows us to keep state to squelch repeat events, because I don't want 1,000 notifications that I am mowing the grass.
# At the end of this script, take whatever context you want to have next time you are called and serialize it
# in a safe manner as shown.  NOTE that the persistent context only persists as long as the current instance of 
# zminstantnotify.pl is running. Want longer persistence?  You could save it to a ramdisk or real disk/ssd.
#
# The main reason for this action script being separate is pretty simple.  This script gets freshly loaded
# each time a zoneminder event occurs, so you can make changes to your criteria and logic
# and these changes will be honored on the very next event.  Could I have used a config file or something?
# Sure, but I often make logic changes, etc. and I don't have to restart zm or go through other 
# machinations to honor my latest changes.  
#
# Out of the box, this is ready for you to plug in pushover.com credentials and requests.  I have no affiliation
# with pushover other than being a brand new user of it.
#
# You can alter this script to call ifttt to turn on lights or voip call you.
#
# Or you could use it to send emails or whatever.
#
# I chose the pushover integration because it's smartphone app allows you to be notified 
# with one of many selectable sounds.  Pushover also provides VERY COOL option to have an emergency 
# notification that will bug you until you confirm receipt.  The pushover app has its own
# in-app snooze (minutes, hours, days) in case you have a rainy windy day that blows up your phone with notifications.
# Obviously you have to create your own pushover account if you go this route.
#
# ZM filters were never really designed for real time event / alarm handling.
# I cannot tell you how much time I wasted over the years trying to get the zmfilter
# do event handling.  ZM filters are great for creating views, but are clunky, slow, and hard to debug for actions.
#
# I added much logging so that you can see exactly what decisions are being made and why.  Note
# that there are data dump logging events commented out that you can uncomment to see great detail.
# Look for the DEBUG variable to see the internals in action in the log.
#
# Future features & thoughts
#   -Send image of alarmed event.  Pushover supports an image in the notification.  Emails would also.
#   -Send url of event for quick access
#   -Would love to see this shipped in zoneminder with actions commented out
#   -This would be easy to wrap a UI around and the UI could be smart enough to offer picklists of monitors and zones
#   -Maybe support ignore zones (though now we are getting out of KISS)
#
# Note that I had to turn off the -T option on line 1 to get this script to call curl.
#
# Props to https://github.com/pliablepixels for the shared memory alarm detection guts.
# Going to shared memory has almost zero overhead, so you could poll every 100ms or less
# on a decent system and not impact the system at all.
# 
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================

my $DISABLE_ALL_ACTIONS = 0;  # If you want to turn off all actions temporarily

my $DEBUG = 0;  # 1 for verbose debug logging, 0 turns off extra debug logging
my $VERBOSE_LOGGING = 1;  # set to zero if you don't want to hear about events that do not match criteria, etc.


use Data::Dumper;
use File::Basename;
use MIME::Base64 (encode_base64url, decode_base64url);

use strict;
use bytes;

use lib '/usr/local/lib/x86_64-linux-gnu/perl5';
use ZoneMinder;
use POSIX;
use DBI;
use Time::HiRes qw(usleep);
use Storable qw(freeze thaw);

# Get parameters from zminstantnotify.pl
my ($initial_loop, $last_event, $mid, $name, $alarm_cause, $encoded_frozen_notification_history) = @ARGV;
if ($initial_loop eq undef || $initial_loop eq "") { Error ("initial_loop parameter is required."); exit(16);}
if ($last_event eq undef || $last_event eq "") { Error ("last_event parameter is required."); exit(16);}
if ($mid eq undef || $mid eq "") { Error ("mid parameter is required."); exit(16);}
if ($name eq undef || $name eq "") { Error ("name parameter is required."); exit(16);}
if ($alarm_cause eq undef) { Error ("alarm_cause parameter is required."); exit(16);}  # alarm cause is usually present, but not always

Info( "========Received new event $last_event for monitor id '$mid' named '$name' caused by '$alarm_cause' with initial loop = $initial_loop\n");


# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================
my $ignore_initial_lingering_events = 1;  # ignore any events received in zminstantnotify.pl's very first loop (at zm restart) to prevent re-notifications

# ADD YOUR STUFF HERE
# defaults to use for all watches
my $po_token = "xxx";  # Get your app token from pushover. See https://pushover.net/api
my $po_user = "xxx";   # Get your user string from pushover.  It is NOT your email.  See https://pushover.net/api
my $po_priority = "0"; # -2=only increment icon counter, -1=no sound, 0=normal, 1=high, 2=emergency (emergency gives non-stop alarm)  https://pushover.net/api#priority
my $po_retry = "30"; # for priority=2, this is seconds between retry to notify user  https://pushover.net/api#priority
my $po_expire = "610"; # for priority=2, this is seconds for total retry period  https://pushover.net/api#priority
my $po_sound = "updown"; # https://pushover.net/api#sounds
my $po_message = "Generated by your custom zoneminder event notification script";
my $po_url = "https://api.pushover.net/1/messages.json";

# ADD YOUR STUFF HERE
my @eventsToWatch = (

	# First Watch
	{
		'name' => "Squirrel who caused \$1400 in wiring and roof damage is in the trap",
		'enabled' => 1,	
		'monitor_id' => '17',	# Zone id.  better than name because name can change name and break these notifications
		'cause' => 'Motion',    		# Empty string matches all causes. Only first word is matched. 'Motion' or 'Forced' is only thing coded/tested/supported.  Only first word is used, so Forced instead of Forced Web
		'zone' => 'squirrel',  			# Empty string matches all zone events, otherwise that zone must be present (not exclusive; additional zones may be present)
		'flavor' => 'pushover', 	# pushover or some other options that you add.  This is currently ignored.
		'squelch_interval' => 2*60, # (seconds) After notifying you, any additional alarms will be ignored during this period in seconds
		'po_token' => $po_token,	# See https://pushover.net/api.  This is not global because you may have different apps/groups.
		'po_user' => $po_user,		# See https://pushover.net/api. This is not global because you may have different user/apps/groups.
		'po_priority' => 2, # 2=EMERGENCY!  Values: -2=only increment icon counter, -1=no sound, 0=normal, 1=high, 2=emergency (emergency gives non-stop alarm)  https://pushover.net/api#priority	
		'po_retry' => $po_retry,	# Only applies to priority = 2 / emergency
		'po_expire' => $po_expire,	# pushover ignores unless priority is 2 / emergency
		'po_sound' => $po_sound,	# sound for notification, they have 25 or so to pick from
		'po_title' => "Squirrel!!", # notification title. Not an UP! reference. Did I say trap? I really meant licking peanut butter in front of a target.
		'po_message' => "" # if empty string, will substitute event details. Could add an image later or url of alarm
	},

	# Another Watch
	{
		'name' => "Event at basement door",
		'enabled' => 1,	
		'monitor_id' => '10',
		'cause' => '',
		'zone' => '', 
		'flavor' => 'pushover',
		'squelch_interval' => 5*60, 
		'po_token' => $po_token,
		'po_user' => $po_user,		
		'po_priority' => 1,
		'po_retry' => $po_retry,
		'po_expire' => $po_expire,
		'po_sound' => $po_sound,
		'po_title' => "",	# Empty string means use watch name as pushover notification title
		'po_message' => ""
	},

	# Another
	{
		'name' => "Motion at front door",
		'enabled' => 1,	
		'monitor_id' => '1',	
		'cause' => 'Motion',
		'zone' => 'front_door',  		
		'flavor' => 'pushover',
		'squelch_interval' => 5*60,
		'po_token' => $po_token,
		'po_user' => $po_user,		
		'po_priority' => $po_priority,	
		'po_retry' => $po_retry,
		'po_expire' => $po_expire,
		'po_sound' => 'tugboat',
		'po_title' => "",	# Empty string means use watch name as pushover notification title
		'po_message' => ""
	},

	# And Another
	{
		'name' => "Front Fence Forced Test",
		'enabled' => 1,	
		'monitor_id' => '19',	
		'cause' => 'Forced',
		'zone' => '', 
		'flavor' => 'pushover',
		'squelch_interval' => 10*60,  # In seconds.  0=NOTIFY ME EVERY SINGLE TIME!!!!
		'po_token' => $po_token,
		'po_user' => $po_user,		
		'po_priority' => 0, 
		'po_retry' => $po_retry,	
		'po_expire' => $po_expire,	
		'po_sound' => "bike",
		'po_title' => "",	# Empty string means use watch name as pushover notification title
		'po_message' => ""
	},
);


# ==========================================================================
#
# Don't change anything below here (Of course you can change anything, but just being clear on beginner vs. advanced)
#
# ==========================================================================

# Since the last execution of this script, the user may have added watches, 
# so fill in the blanks on the notification history entries to account for new ones.
# There is no garbage collection of old ones, but this should not be an issue
# because these are low volume changes and what if someone typo'ed on temporarily
my %notification_history;
foreach (@eventsToWatch) {
	my $watch_key = "$_->{'monitor_id'}---$_->{'cause'}---$_->{'zone'}";
	if (undef == $notification_history{$watch_key}) {
		if ($DEBUG) {Info ("Priming \$watch_key=$watch_key=0");}
		$notification_history{$watch_key} = 0;
	}
}

# The persisted context was frozen and encoded to be suitable to pass as a parameter, so thaw it
my %storedHistory;

if ($DEBUG) {Info ("encoded and frozen notification history = ".Dumper($encoded_frozen_notification_history));}

if ($encoded_frozen_notification_history ne undef && $encoded_frozen_notification_history ne "") {
	$encoded_frozen_notification_history =  $encoded_frozen_notification_history;   # Passing equal sign to perl give safety error, so stripped it and now put it back
	my $frozen_notification_history = decode_base64url($encoded_frozen_notification_history);
	if ($DEBUG) {Info("\$frozen_notification_history=$frozen_notification_history");}
	%storedHistory = %{thaw $frozen_notification_history};
	if ($DEBUG) {Info("\%storedHistory=%storedHistory");}
}

# Merge the persistent history in with the strawman history
my $key;
foreach $key (keys %storedHistory) {
	$notification_history{$key} = $storedHistory{$key};
	if ($DEBUG) {Info ("Updating from passed context \$watch_key=$key=$notification_history{$key}");}
}

# # DEBUG CHECK
# foreach $key (keys %notification_history) {
# 	if ($DEBUG) {Info ("notification history check \$watch_key=$key=$notification_history{$key}");}
# }

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

logInit();
logSetSignal();

if ($DISABLE_ALL_ACTIONS) {

	Warn ("All actions are currently disabled on zminstantnotify-actions.pl ");

} else {

	foreach (@eventsToWatch) {

		my $watch_key = "$_->{'monitor_id'}---$_->{'cause'}---$_->{'zone'}";
		my $last_notified_time = %notification_history{$watch_key};

		my $shouldConsider = !($ignore_initial_lingering_events && $initial_loop); # yes, should be outside, so sue me :)
		if (!$shouldConsider) {Info ("Skipping one eventToWatch because ignore initial loop is set");}

		my $disabled = (!$_->{'enabled'});
		my $matchMid = ($mid == $_->{'monitor_id'});
		my $matchCause = ((split / /, $alarm_cause)[0] eq $_->{'cause'});
		my $matchZone = (($_->{'zone'} eq "") || (index($alarm_cause, $_->{'zone'}) != -1));
		if ( $_->{'zone'} eq "Motion" ) {Warn ("Do not name your zone Motion or add that corner case to the code");}

		if ($disabled) { Info("The watch for monitor id '$_->{'monitor_id'}' cause '$_->{'cause'}' zone '$_->{'zone'}' watch is set to disabled");}

		if (!$disabled && $shouldConsider && $matchMid && $matchZone) {					

			if ($VERBOSE_LOGGING) { Info("Event $last_event does match the watch: monitor id '$_->{'monitor_id'}' cause '$_->{'cause'}' zone '$_->{'zone'}'");}
			if ($VERBOSE_LOGGING) { Info("Checking squelch for this watch to see if action was already triggered too recently.");}

			# There is a match.  Are we in the squelch time period?  Has user been recently notified?
			my $squelch_interval = $_->{'squelch_interval'};
			my $squelched = ((time() - $squelch_interval) < $last_notified_time);

			if ($VERBOSE_LOGGING) {Info( "Current time ".time()."- squelch_interval $squelch_interval) > $last_notified_time" );}

			if ($squelched) {
				Info("Squelching notification for $_->{'monitor_id'} $_->{'cause'} $_->{'zone'}) ");
			} else {

				$notification_history{$watch_key} = time();  # reset squelch timer to begin now
				if ($DEBUG) {Info( "new last notified time for future squelching = $notification_history{$watch_key}" );}

				my $title;
				# if empty po_title is specified, then use watch name
				if ($_->{'po_title'} eq "") {
					$title = $_->{'name'};
				} else {
					$title = $_->po_title;
				}

				my $message;
				# if empty po_message is specified, then use watch name
				if ($_->{'po_message'} eq "") {
					$message = "ZM Alarm: $name $alarm_cause";
				} else {
					$message = $_->{'po_message'};
				}


				# ADD YOUR STUFF HERE
				# This is where I call pushover, but you could do anything.  You could call ifttt, could email, 
				# could call a service that provides a webhook for email or SMS.  The sky is the limit. Have fun.
				my $curl;
				Info ("We have a hit.  Sending notification...");
				if ($DEBUG) {Info ("curl -s -F \"token=$_->{'po_token'}\" -F \"user=$_->{'po_user'}\" -F \"priority=$_->{'po_priority'}\"  -F \"expire=$_->{'po_expire'}\"  -F \"retry=$_->{'po_retry'}\"  -F \"title=$title\" -F \"sound=$_->{'po_sound'}\" -F \"message=$message\" $po_url");}
				$curl = `curl -s -F "token=$_->{'po_token'}" -F "user=$_->{'po_user'}" -F "priority=$_->{'po_priority'}"  -F "expire=$_->{'po_expire'}"  -F "retry=$_->{'po_retry'}"  -F "title=$title" -F "sound=$_->{'po_sound'}" -F "message=$message" $po_url`;
				Info ("Results of sending PushOver: ".$curl."\n");

			}

		} else {
			if (!$disabled && $VERBOSE_LOGGING) { Info("Event $last_event did not match the watch: monitor id '$_->{'monitor_id'}' cause '$_->{'cause'}' zone '$_->{'zone'}'");}
		}
	}
}

if ($DEBUG) { Info ("Notification History=\n".Dumper(%notification_history));}

my $frozen_notification_history = freeze \%notification_history;
my $encoded_frozen_notification_history = encode_base64url($frozen_notification_history);

print $encoded_frozen_notification_history;  # Send context back to caller

exit();
