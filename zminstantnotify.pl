#!/usr/bin/perl
#
# ==========================================================================
#
# THIS SCRIPT MUST BE RUN WITH SUDO OR STARTED VIA ZMDC.PL
#
# ZoneMinder Instant Notification System
#
# tl;dr - zminstantnotify-actions.pl is where you plug in your custom event actions.
#         Look for "ADD YOUR STUFF HERE" for the main areas you might want to hack.
#
# I have been using ZM for about 15 years and I am thankful to those who have 
# contributed.  It is a very cool and fun security addition to my home. Be kind, I think
# this is my first perl script, so it will surely make OCD folks cringe.
#
# This script is a light weight event notification daemon which can be easily changed to call or 
# do whatever you want.  The provided sample actions script calls pushover to send instant notifications
# to your phone.  You can alter it to call ifttt to turn on lights or voip call you.
# Or you could use it to send emails.  
#
# Almost out of the box you can get instant notifications via the pushover smartphone app
# with one of many selectable sounds.  Pushover also provides VERY COOL option to have an emergency 
# notification that will bug you until you confirm receipt.  The pushover app has its own
# in-app snooze in case you have a windy day that blows up your phone with notifications.
# Obviously you have to create your own pushover account if you go this route.
#
# ZM filters were never really designed for real time event / alarm handling.
# I cannot tell you how much time I wasted over the years trying to get the zmfilter
# do this.  ZM filters are great for creating views, but are clunky, slow, and hard to debug for actions.
#
# I added much logging so that you can see exactly what decisions are being made and why.  Note
# that there are data dump logging events commented out that you can uncomment to see great detail.
#
# This script uses shared memory to detect new events (polls SHM), which is 
# lightning FAST with low overhead compared to zmfilter
# as there is no DB overhead nor SQL searches for event matches.  (I did not write this part, see props below)
#
# See the actions script for thoughts on future features, etc.
#
# Props to https://github.com/pliablepixels for the shared memory alarm detection guts.
# Going to shared memory has almost zero overhead, so you could poll every 100ms or less
# on a decent system and not impact the system at all.
# 
# Note that I had to turn off the -T option on line 1 to get this script to call curl.
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

# Uncomment this line to disable the zoneminder copy in case you are running a local copy
# This saves you from editing out the inclusion in zmpkg and zmdc if you only want one 
# copy running during dev and it will remind you in the log that it is in disabled mode. 
#
# A BETTER CHOICE is to set DISABLE_ALL_ACTIONS=1 on /usr/bin/zminstantnotify-actions.pl
# while you are running a local copy for development.
#
# disable();

my $DEBUG = 0;  # 1 for verbose debug logging, 0 turns off extra debug logging

my $VERBOSE_LOGGING = 0;  # set to zero if you don't want to hear about reloading monitors, etc.

use Data::Dumper;
use File::Basename;

use strict;
use bytes;

use lib '/usr/local/lib/x86_64-linux-gnu/perl5';
use ZoneMinder;
use POSIX;
use DBI;
use Time::HiRes qw(usleep);
use Storable qw(nstore store_fd nstore_fd freeze thaw dclone);

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================
use constant MONITOR_RELOAD_INTERVAL => 30;
my $EVENT_CHECK_INTERVAL_IN_MILLISECONDS = 250;

# ==========================================================================
#
# Don't change anything below here
#
# ==========================================================================
$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

logInit();
logSetSignal();

Info( "Instant Notifier for ZM daemon starting\n" );

my $frozen_encoded_frozen_action_persisted_context;

my $dbh = zmDbConnect();
my %monitors;
my $monitor_reload_time = 0;
my @events=();

my $alarm_header="";
my $event_loop_count = 0;
my $announce_loop_count = 10;

my $initial_loop = 1;


# MAIN
doForever();

Info( "Instant Notifier for ZM daemon exiting\n" );  # dead code
exit();

# Try to load a perl module
# and if it is not available 
# generate a log 
sub try_use 
{
  my $module = shift;
  eval("use $module");
  return($@ ? 0:1);
}


# This function uses shared memory polling to check if 
# ZM reported any new events. If it does find events
# then the details are packaged into the events array
# so they can be JSONified and sent out
sub checkEvents()
{

	my $eventFound = 0;

	if ( (time() - $monitor_reload_time) > MONITOR_RELOAD_INTERVAL )
    	{

		if ($VERBOSE_LOGGING) {Info ("Reloading Monitors...\n");}
		foreach my $monitor (values(%monitors))
		{
			zmMemInvalidate( $monitor );
		}
		loadMonitors();
	}

	@events = ();
	foreach my $monitor ( values(%monitors) )
	{ 

		# https://github.com/ZoneMinder/zoneminder/blob/master/scripts/ZoneMinder/lib/ZoneMinder/Memory.pm.in
		my ( $state, $last_event, $alarm_cause )
		    = zmMemRead( $monitor,
				 [ "shared_data:state",
				   "shared_data:last_event",
				   "shared_data:alarm_cause"
				 ]
		);

		if ($state == STATE_ALARM || $state == STATE_ALERT)
		{
			if ( !defined($monitor->{LastEvent})
                 	     || ($last_event != $monitor->{LastEvent}))
			{

				$monitor->{LastState} = $state;
				$monitor->{LastEvent} = $last_event;
				my $name = $monitor->{Name};
				my $mid = $monitor->{Id};
				my $eid = $last_event;

				Info( "===> Calling zminstantnotify-actions.pl for new event $last_event for monitor id '$mid' named '$name' caused by '$alarm_cause'\n");

				if ($DEBUG) {Info ("CALLING: ./zminstantnotify-actions.pl \"$initial_loop\" \"$last_event\" \"$mid\" \"$name\" \"$alarm_cause\" \"$frozen_encoded_frozen_action_persisted_context\"");}
				my $result = `./zminstantnotify-actions.pl "$initial_loop" "$last_event" "$mid" "$name" "$alarm_cause" "$frozen_encoded_frozen_action_persisted_context"`;

				if ($DEBUG) {Info( "Result of zminstantnotify-actions.pl: $result\n");}
				$frozen_encoded_frozen_action_persisted_context = $result;


			}
		}
	}
}



# Refreshes list of monitors from DB
sub loadMonitors
{
    $monitor_reload_time = time();

    my %new_monitors = ();

    my $sql = "SELECT * FROM Monitors
               WHERE find_in_set( Function, 'Modect,Mocord,Nodect' )"
    ;
    my $sth = $dbh->prepare_cached( $sql )
        or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute()
        or Fatal( "Can't execute: ".$sth->errstr() );
    while( my $monitor = $sth->fetchrow_hashref() )
    {
        next if ( !zmMemVerify( $monitor ) ); # Check shared memory ok

        if ( defined($monitors{$monitor->{Id}}->{LastState}) )
        {
            $monitor->{LastState} = $monitors{$monitor->{Id}}->{LastState};
        }
        else
        {
            $monitor->{LastState} = zmGetMonitorState( $monitor );
        }
        if ( defined($monitors{$monitor->{Id}}->{LastEvent}) )
        {
            $monitor->{LastEvent} = $monitors{$monitor->{Id}}->{LastEvent};
        }
        else
        {
            $monitor->{LastEvent} = zmGetLastEvent( $monitor );
        }
        $new_monitors{$monitor->{Id}} = $monitor;
    }
    %monitors = %new_monitors;
}


# This function compares the password provided over websockets
# to the password stored in the ZM MYSQL DB
sub validateZM
{
	my ($u,$p) = @_;
	return 0 if ( $u eq "" || $p eq "");
	my $sql = 'select Password from Users where Username=?';
	my $sth = $dbh->prepare_cached($sql)
	 or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $u )
	or Fatal( "Can't execute: ".$sth->errstr() );
	if (my ($state) = $sth->fetchrow_hashref())
	{
		my $encryptedPassword = password41($p);
		$sth->finish();
		return $state->{Password} eq $encryptedPassword ? 1:0; 
	}
	else
	{
		$sth->finish();
		return 0;
	}
}


# This is really the main module
sub doForever
{
	if ($VERBOSE_LOGGING) {Info ("Starting event check loop");}

	while (1) {

		checkEvents();

		$initial_loop = 0;

		if ( $event_loop_count == $announce_loop_count) {
			$event_loop_count = 0;
			Info ("$announce_loop_count more event check loops have run, just to let you know I am still alive and well");
		}

		usleep($EVENT_CHECK_INTERVAL_IN_MILLISECONDS);  # milliseconds where 1000 = 1 second
	}
}


# By uncommenting near the beginning, this will be called when you are running your dev script yourself 
# and don't want both scripts trying to process the same events
sub disable
{
	while (1) {
		Info ("this script is disabled.  change the code to re-enable");
		select(undef, undef, undef, 10.0);
	}
}
