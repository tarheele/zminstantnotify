
### This is the lightweight, simple, instant ZM event notification that you crave!!!
This script is a light weight event notification daemon which can be easily changed to call or 
do whatever you want.  The provided sample actions script calls pushover to send instant notifications
to your phone.  You can alter it to call ifttt to turn on lights or voip call you.
Or you could use it to send emails.  

Almost out of the box you can get instant notifications via the pushover smartphone app
with one of many selectable sounds.  Pushover also provides VERY COOL option to have an emergency 
notification that will bug you until you confirm receipt.  The pushover app has its own
in-app snooze in case you have a windy day that blows up your phone with notifications.
Obviously you have to create your own pushover account if you go this route.

### TLDR
* Follow the instructions below to install zminstantnotify.pl and have it started by ZM as a deamon.
* Put zminstantnotify-actions.pl in the same directory.
* Look for "ADD YOUR STUFF HERE" for code you might want to hack, mainly in the actions script

### Thanks to ZoneMinder Authors / Contributors
I have been using ZM for about 15 years and I am thankful to those who have 
contributed.  It is a very cool and fun security addition to my home. 

Be kind, I have been programming many years, but I think this is my first non-trivial perl script, so it will surely make OCD folks cringe.  This was developed under the Get R Done model.

### Supported versions
I developed this on 1.32.3 and will be upgrading soon.  Try it and see if it works in 1.32+.  
The script only tries to read from shared memory and does not write, so it should not have any 
side effects on other ZM components.

### Why do we need it?
* The only way ZoneMinder sends out event notifications via event filters - this is too slow
* You will love how simple this is.  No crazy clients or setup.  Just install edit and go.


### Is this officially developed by ZM developers?
No, but it would be great if it was included.

### Read the headers of the files and the comments in the code
I tried to be concise and explain things via the code and logging statements.

### Why did I create this?
ZM filters were never really designed for real time event / alarm handling.

I cannot tell you how much time I wasted over the years trying to get the zmfilter
do this.  ZM filters are great for creating views, but are clunky, slow, and hard to debug for actions.

### Logging
Both scripts logs to the zoneminder log in their own file entries.  Use the File pulldown to select either one of the scripts.

If you do not seen an entry for the actions script, then actions may not have occurred recently.
Trigger an alarm and then look again.

If you are running it standalone to test (and you should), 
you will send log entries to stdout.

I added much logging so that you can see exactly what decisions are being made and why.  Note
that there are data dump logging events enabled via $DEBUG and some are commented out that you can uncomment to see great detail.

### Squelch feature
I don't want 1,000 notifications that I am mowing the grass.  If you are turning on a light with ifttt or something, then
you may not care about squelching.

On each watch that you set in the actions script, you set a squelch time in seconds.  If you configure 10*60 seconds (10 mins)
Then you will only get notified for events at least 10 minutes apart. 

To keep track of this, we keep a semi-persistent state.

This action script receives as parameters the current event information as well as a persistent context.  The persistent context
allows us to keep state to squelch repeat events.

At the end of the action script, we take whatever context we want to have next time we are called and serialize it
in a safe manner as shown.  NOTE that the persistent context only persists as long as the current instance of 
zminstantnotify.pl is running. Want longer persistence?  You could save it to a ramdisk or real disk/ssd.

### This script is very fast with almost zero overhead
This script uses shared memory to detect new events (polls SHM), which is 
lightning FAST with low overhead compared to zmfilter
as there is no DB overhead nor SQL searches for event matches.  (I did not write this part, see props below)

### Props
Props to https://github.com/pliablepixels for the shared memory alarm detection guts.
Going to shared memory has almost zero overhead, so you could poll every 100ms or less
on a decent system and not impact the system at all.

### Where can I get it?
* Grab the script from this repository - it is two perl files
* Place it along with other ZM scripts (see below)

### How do I install it?

* Grab both pl files and place them in the same place other ZM scripts are stored (example ``/usr/bin``)
* Either run it manually like ``sudo /usr/bin/zmeventnotification.pl`` or add it as a daemon to ``/usr/bin/zmdc.pl`` (the advantage of the latter is that it gets automatically started when ZM starts
and restarted if it crashes)

##### How do I run it as a daemon so it starts automatically along with ZoneMinder?

**WARNING: Do NOT do this before you run it manually as I've mentioned above to test. Make sure it works, all packages are present etc. before you 
add it as  a daemon as if you don't and it crashes you won't know why**

(Note if you have compiled from source using cmake, the paths may be ``/usr/local/bin`` not ``/usr/bin``)

* Copy ``zminstantnotification.pl`` and ``zminstantnotification-actions.pl`` to ``/usr/bin``
* Edit ``/usr/bin/zmdc.pl`` and in the array ``@daemons`` (starting line 80) add ``'zminstantnotification.pl'`` like [this](https://gist.github.com/pliablepixels/18bb68438410d5e4b644 - but file name is different)
* Edit ``/usr/bin/zmpkg.pl`` and around line 260, right after the comment that says ``#this is now started unconditionally`` and right before the line that says ``runCommand( "zmdc.pl start zmfilter.pl" );`` start zmeventnotification.pl by adding ``runCommand( "zmdc.pl start zminstantnotification.pl" );`` like  [this](https://gist.github.com/pliablepixels/0977a77fa100842e25f2 - but file name is different)
* Make sure you restart ZM. Rebooting the server is better - sometimes zmdc hangs around and you'll be wondering why your new daemon hasn't started
* To check if its running do a ``zmdc.pl status zminstantnotification.pl``

You can/should run it manually at first to check if it works 

