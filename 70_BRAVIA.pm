# $Id$
##############################################################################
#
#     70_BRAVIA.pm
#     An FHEM Perl module for controlling Sony Televisons
#     via network connection. Supported are models with release date starting from 2011.
#     inspired by Philips Televisions Module from Julian Pawlowski <julian.pawlowski at gmail.com>
#
#     Copyright by Ulf von Mersewsky
#     e-mail: umersewsky at gmail.com
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
#
# Version: 0.4.5
#
# Major Version History:
# 
##############################################################################

package main;

use 5.012;
use strict;
use warnings;
use Data::Dumper;
use Time::HiRes qw(gettimeofday);
use Time::Local;
use HttpUtils;
use SetExtensions;
use Encode;
use JSON qw(decode_json);
use MIME::Base64;
use XML::Simple;
use IO::Socket;

sub BRAVIA_Set($@);
sub BRAVIA_Get($@);
sub BRAVIA_GetStatus($;$);
sub BRAVIA_Define($$);
sub BRAVIA_Undefine($$);

#########################
# Forward declaration for remotecontrol module
#sub BRAVIA_RClayout_TV();
#sub BRAVIA_RCmakenotify($$);

###################################
sub BRAVIA_Initialize($) {
    my ($hash) = @_;

    Log3 $hash, 5, "BRAVIA_Initialize: Entering";

    $hash->{GetFn}   = "BRAVIA_Get";
    $hash->{SetFn}   = "BRAVIA_Set";
    $hash->{DefFn}   = "BRAVIA_Define";
    $hash->{UndefFn} = "BRAVIA_Undefine";

    $hash->{AttrList} =
"disable:0,1 timeout inputs macaddr:textField "
      . $readingFnAttributes;

    $data{RC_layout}{BRAVIA_SVG} = "BRAVIA_RClayout_SVG";
    $data{RC_layout}{BRAVIA}     = "BRAVIA_RClayout";

    $data{RC_makenotify}{BRAVIA} = "BRAVIA_RCmakenotify";

    return;
}

#####################################
sub BRAVIA_GetStatus($;$) {
    my ( $hash, $update ) = @_;
    my $name     = $hash->{NAME};
    my $interval = $hash->{INTERVAL};

    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_GetStatus()";

    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday() + $interval, "BRAVIA_GetStatus", $hash, 0 );

    return
      if ( defined( $attr{$name}{disable} ) && $attr{$name}{disable} == 1 );

    # check device availability
    if (!$update) {
      BRAVIA_SendCommand( $hash, "getStatus", "xml" )
          if (!defined($hash->{READINGS}{requestFormat}{VAL}) ||
              $hash->{READINGS}{requestFormat}{VAL} eq "xml");
      BRAVIA_SendCommand( $hash, "getStatus", "json" )
          if (!defined($hash->{READINGS}{requestFormat}{VAL}) ||
              $hash->{READINGS}{requestFormat}{VAL} eq "json");
    }

    return;
}

###################################
sub BRAVIA_Get($@) {
    my ( $hash, @a ) = @_;
    my $name = $hash->{NAME};
    my $what;

    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_Get()";

    return "argument is missing" if ( int(@a) < 2 );

    $what = $a[1];

    if ( $what =~ /^(power|input|volume|mute)$/ ) {
        if ( defined( $hash->{READINGS}{$what}{VAL} ) ) {
            return $hash->{READINGS}{$what}{VAL};
        }
        else {
            return "no such reading: $what";
        }
    }

    else {
        return
"Unknown argument $what, choose one of power:noArg input:noArg volume:noArg mute:noArg";
    }
}

###################################
sub BRAVIA_Set($@) {
    my ( $hash, @a ) = @_;
    my $name  = $hash->{NAME};
    my $state = $hash->{READINGS}{state}{VAL};
    my $channel =
      ( $hash->{READINGS}{channel}{VAL} )
      ? $hash->{READINGS}{channel}{VAL}
      : "";
    my $channelId =
      ( $hash->{READINGS}{channelId}{VAL} )
      ? $hash->{READINGS}{channelId}{VAL}
      : "";
    my $channels   = "";
    my $inputs_txt = "";
    my $mutes = "toggle";

    if ( defined( $hash->{READINGS}{input}{VAL} )
        && $hash->{READINGS}{input}{VAL} ne "-" )
    {
        $hash->{helper}{lastInput} = $hash->{READINGS}{input}{VAL};
    }
    elsif ( !defined( $hash->{helper}{lastInput} ) ) {
        $hash->{helper}{lastInput} = "";
    }

    my $input = $hash->{helper}{lastInput};

    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_Set()";

    return "No Argument given" if ( !defined( $a[1] ) );

    # Input alias handling
    if ( defined( $attr{$name}{inputs} ) && $attr{$name}{inputs} ne "" ) {
        my @inputs = split( ':', $attr{$name}{inputs} );
        $inputs_txt = "-," if ( $state ne "on" );

        if (@inputs) {
            foreach (@inputs) {
                if (m/[^,\s]+(,[^,\s]+)+/) {
                    my @input_names = split( ',', $_ );
                    $inputs_txt .= $input_names[1] . ",";
                    $input_names[1] =~ s/\s/_/g;
                    $hash->{helper}{device}{inputAliases}{ $input_names[0] } =
                      $input_names[1];
                    $hash->{helper}{device}{inputNames}{ $input_names[1] } =
                      $input_names[0];
                }
                else {
                    $inputs_txt .= $_ . ",";
                }
            }
        }

        $inputs_txt =~ s/\s/_/g;
        $inputs_txt = substr( $inputs_txt, 0, -1 );
    }

    # load channel list
    my @channels;
    if ( defined( $hash->{helper}{device}{channelPreset} )
        && ref( $hash->{helper}{device}{channelPreset} ) eq "HASH" )
    {
      foreach my $preset ( keys %{ $hash->{helper}{device}{channelPreset} } ) {
        if ( $hash->{helper}{device}{channelPreset}{$preset}{name}
            && $hash->{helper}{device}{channelPreset}{$preset}{name} ne ""
            && $hash->{helper}{device}{channelPreset}{$preset}{name} ne "-"
            && $hash->{helper}{device}{channelPreset}{$preset}{id} ne "-" ) {
          push(
              @channels,
              $hash->{helper}{device}{channelPreset}{$preset}{id}.":".$hash->{helper}{device}{channelPreset}{$preset}{name});
        }
      };
    }
    if ( $channel ne "" && $channel ne "-" && $channelId ne "-" ) {
        my $currentChannel = $channelId . ":" . $channel;
        my @matches = grep("/".$currentChannel."/", @channels);
        push( @channels, $currentChannel ) if ( ( scalar @matches ) eq "0" );
    }
    @channels = sort(@channels);
    if ( ( scalar @channels ) gt "80" ) {
      @channels = splice(@channels, 80);
    }
    $channels = join(",", @channels);

    $mutes .= ",on,off";
    #$mutes .= ",off" if ( defined( $hash->{READINGS}{generation}{VAL} ) and $hash->{READINGS}{generation}{VAL} ne "1.0" );

    my $usage = "Unknown argument " . $a[1] . ", choose one of";
    $usage .= " requestFormat:json,xml register";
    $usage .= ":noArg"
        if (defined($hash->{READINGS}{requestFormat}{VAL}) &&
            $hash->{READINGS}{requestFormat}{VAL} eq "xml");
    $usage .= " statusRequest:noArg toggle:noArg on:noArg off:noArg tvpause:noarg play:noArg pause:noArg stop:noArg record:noArg upnp:on,off volume:slider,1,1,100 volumeUp:noArg volumeDown:noArg channelUp:noArg channelDown:noArg remoteControl";
    $usage .= " mute:" . $mutes;
    $usage .= " input:" . $inputs_txt if ( $inputs_txt ne "" );
    $usage .= " channel:$channels" if ( $channels ne "" );

    my $cmd = '';
    my $result;

    # statusRequest
    if ( lc( $a[1] ) eq "statusrequest" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        delete $hash->{helper}{device}
          if ( defined( $hash->{helper}{device} ) );

        BRAVIA_GetStatus($hash);
    }

    # toggle
    elsif ( $a[1] eq "toggle" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} ne "on" ) {
            return BRAVIA_Set( $hash, $name, "on" );
        }
        else {
            return BRAVIA_Set( $hash, $name, "off" );
        }

    }

    # on
    elsif ( $a[1] eq "on" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} ne "on" ) {
            my $macAddr = AttrVal( $name, "macaddr", "" );
            $macAddr = ReadingsVal( $name, "macAddr", "") if ($macAddr eq "");
            if ( $macAddr ne "" && $macAddr ne "-" ) {
                $result = BRAVIA_wake( $name, $macAddr );
                return "wake-up command sent";
            } else {
                $cmd = "POWER";
                BRAVIA_SendCommand( $hash, "ircc", $cmd );
            }
        }
    }

    # off
    elsif ( $a[1] eq "off" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} ne "absent" ) {
            if ( defined($hash->{READINGS}{generation}{VAL}) && $hash->{READINGS}{generation}{VAL} ne "1.0" ) {
              $cmd = "STANDBY";
            } else {
              $cmd = "POWER";
            }
            BRAVIA_SendCommand( $hash, "ircc", $cmd );
        }
        else {
            return "Device needs to be reachable to toggle standby mode.";
        }
    }

    # volume
    elsif ( $a[1] eq "volume" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];

        return "No argument given" if ( !defined( $a[2] ) );

        my $vol = $a[2];
        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            if ( $vol =~ m/^\d+$/ && $vol >= 1 && $vol <= 100 ) {
                $cmd = 'setVolume:' . $vol;
            }
            else {
                return
"Argument does not seem to be a valid integer between 1 and 100";
            }
            BRAVIA_SendCommand( $hash, "upnp", $cmd );

            readingsSingleUpdate( $hash, "volume", $a[2], 1 )
              if ( $hash->{READINGS}{volume}{VAL} ne $a[2] );
        }
        else {
            return "Device needs to be ON to adjust volume.";
        }
    }

    # volumeUp/volumeDown
    elsif ( lc( $a[1] ) =~ /^(volumeup|volumedown)$/ ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            if ( lc( $a[1] ) eq "volumeup" ) {
                $cmd = "VOLUP";
            }
            else {
                $cmd = "VOLDOWN";
            }
            BRAVIA_SendCommand( $hash, "ircc", $cmd );
        }
        else {
            return "Device needs to be ON to adjust volume.";
        }
    }

    # mute
    elsif ( $a[1] eq "mute" ) {
        if ( defined( $a[2] ) ) {
            Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];
        }
        else {
            Log3 $name, 2, "BRAVIA set $name " . $a[1];
        }

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            if ( !defined( $a[2] ) || $a[2] eq "toggle" ) {
                $result = BRAVIA_SendCommand( $hash, "ircc", "MUTE" );
                readingsSingleUpdate( $hash, "mute", ($hash->{READINGS}{mute}{VAL} eq "on" ? "off" : "on"), 1 );
            }
            elsif ( $a[2] eq "off" ) {
                #$result = BRAVIA_SendCommand( $hash, "MuteOff" )
                $result = BRAVIA_SendCommand( $hash, "upnp", "setMute:0" );
                readingsSingleUpdate( $hash, "mute", $a[2], 1 )
                   if ( $hash->{READINGS}{mute}{VAL} ne $a[2] );
            }
            elsif ( $a[2] eq "on" ) {
                #$result = BRAVIA_SendCommand( $hash, "MuteOn" )
                $result = BRAVIA_SendCommand( $hash, "upnp", "setMute:1" );
                readingsSingleUpdate( $hash, "mute", $a[2], 1 )
                   if ( $hash->{READINGS}{mute}{VAL} ne $a[2] );
            }
            else {
                return "Unknown argument " . $a[2];
            }
        }
        else {
            return "Device needs to be ON to mute/unmute audio.";
        }
    }

    # remoteControl
    elsif ( lc( $a[1] ) eq "remotecontrol" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];

        if ( $hash->{READINGS}{state}{VAL} ne "absent" ) {
            if ( !defined( $a[2] ) ) {
                my $commandKeys = "";
                for (
                    sort keys %{
                        BRAVIA_GetRemotecontrolCommand(
                            "GetRemotecontrolCommands")
                    }
                  )
                {
                    $commandKeys = $commandKeys . " " . $_;
                }
                return "No argument given, choose one of" . $commandKeys;
            }

            $cmd = uc( $a[2] );

            if ( $cmd eq "MUTE" ) {
                BRAVIA_Set( $hash, $name, "mute" );
            }
            elsif ( $cmd eq "CHANUP" ) {
                BRAVIA_Set( $hash, $name, "channelUp" );
            }
            elsif ( $cmd eq "CHANDOWN" ) {
                BRAVIA_Set( $hash, $name, "channelDown" );
            }
            elsif ( $cmd ne "" ) {
                BRAVIA_SendCommand( $hash, "ircc", $cmd );
            }
            else {
                my $commandKeys = "";
                for (
                    sort keys %{
                        BRAVIA_GetRemotecontrolCommand(
                            "GetRemotecontrolCommands")
                    }
                  )
                {
                    $commandKeys = $commandKeys . " " . $_;
                }
                return
                    "Unknown argument "
                  . $a[2]
                  . ", choose one of"
                  . $commandKeys;
            }
        }
        else {
            return "Device needs to be reachable to be controlled remotely.";
        }
    }

    # channel
    elsif ( $a[1] eq "channel" ) {
        if (   defined( $a[2] )
            && $hash->{READINGS}{presence}{VAL} eq "present"
            && $hash->{READINGS}{state}{VAL} ne "on" )
        {
            Log3 $name, 4, "BRAVIA $name: indirect switching request to ON";
            BRAVIA_Set( $hash, $name, "on" );
        }

        Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];

        return
          "No argument given, choose one of channel presetNumber channelName "
          if ( !defined( $a[2] ) );

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            my $channelName = $a[2];
            if ( $channelName =~ /^(\d)(\d?)(\d?)(\d?):.*$/ ) {
              BRAVIA_SendCommand( $hash, "ircc", $1, "blocking" );
              BRAVIA_SendCommand( $hash, "ircc", $2, "blocking" ) if (defined($2));
              BRAVIA_SendCommand( $hash, "ircc", $3, "blocking" ) if (defined($3));
              BRAVIA_SendCommand( $hash, "ircc", $4, "blocking" ) if (defined($4));
            } else {
                return "Argument " . $channelName . " is not a valid channel name";
            }
        }
        else {
            return
              "Device needs to be reachable to switch to a specific channel.";
        }
    }

    # channelUp/channelDown
    elsif ( lc( $a[1] ) =~ /^(channelup|channeldown)$/ ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            if ( lc( $a[1] ) eq "channelup" ) {
                $cmd = "CHANUP";
            }
            else {
                $cmd = "CHANDOWN";
            }
            BRAVIA_SendCommand( $hash, "ircc", $cmd );
        }
        else {
            return "Device needs to be ON to switch channel.";
        }
    }

    # input
    elsif ( $a[1] eq "input" ) {
        if (   defined( $a[2] )
            && $hash->{READINGS}{presence}{VAL} eq "present"
            && $hash->{READINGS}{state}{VAL} ne "on" )
        {
            Log3 $name, 4, "BRAVIA $name: indirect switching request to ON";
            BRAVIA_Set( $hash, $name, "on" );
        }

        return "No 2nd argument given" if ( !defined( $a[2] ) );

        Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];

        # Alias handling
        $a[2] = $hash->{helper}{device}{inputNames}{ $a[2] }
          if ( defined( $hash->{helper}{device}{inputNames}{ $a[2] } ) );

        # Resolve input ID name
        my $input_id;
        if ( defined( $hash->{helper}{device}{sourceID}{ $a[2] } ) ) {
            $input_id = $hash->{helper}{device}{sourceID}{ $a[2] };
        }
        elsif ( defined( $hash->{helper}{device}{sourceName}{ $a[2] } ) ) {
            $input_id = $a[2];
        }
        else {
            return "Unknown source input '" . $a[2] . "' on that device.";
        }

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            BRAVIA_SendCommand( $hash, "sources/current",
                '"id": ' . $input_id, $input_id );

            if ( $hash->{READINGS}{input}{VAL} ne $a[2] ) {
                readingsSingleUpdate( $hash, "input", $a[2], 1 );
            }
        }
        else {
            return "Device needs to be reachable to switch input.";
        }
    }

    # tvpause
    elsif ( $a[1] eq "tvpause" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            BRAVIA_SendCommand( $hash, "ircc", "TVPAUSE" );
        }
        else {
            return "Device needs to be ON to pause tv.";
        }
    }

    # pause
    elsif ( $a[1] eq "pause" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            BRAVIA_SendCommand( $hash, "ircc", "PAUSE" );
        }
        else {
            return "Device needs to be ON to pause video.";
        }
    }

    # play
    elsif ( $a[1] eq "play" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            BRAVIA_SendCommand( $hash, "ircc", "PLAY" );
        }
        else {
            return "Device needs to be ON to play video.";
        }
    }

    # stop
    elsif ( $a[1] eq "stop" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            BRAVIA_SendCommand( $hash, "ircc", "STOP" );
        }
        else {
            return "Device needs to be ON to stop video.";
        }
    }

    # record
    elsif ( $a[1] eq "record" ) {
        Log3 $name, 2, "BRAVIA set $name " . $a[1];

        if ( $hash->{READINGS}{state}{VAL} eq "on" ) {
            BRAVIA_SendCommand( $hash, "ircc", "RECORD" );
        }
        else {
            return "Device needs to be ON to start instant recording.";
        }
    }

    # register
    elsif ( $a[1] eq "register" ) {
        if (defined($a[2])) {
          Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];
          BRAVIA_SendCommand( $hash, "register", $a[2] );
        } else {
          Log3 $name, 2, "BRAVIA set $name " . $a[1];
          BRAVIA_SendCommand( $hash, "register" );
        }
    }

    # requestFormat
    elsif ( $a[1] eq "requestFormat" ) {
        return "No 2nd argument given" if ( !defined( $a[2] ) );

        Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];
        readingsSingleUpdate( $hash, "requestFormat", $a[2], 1 )
           if ( !defined($hash->{READINGS}{requestFormat}{VAL}) ||
                $hash->{READINGS}{requestFormat}{VAL} ne $a[2] );
    }

    # upnp
    elsif ( $a[1] eq "upnp" ) {
        return "No 2nd argument given" if ( !defined( $a[2] ) );

        Log3 $name, 2, "BRAVIA set $name " . $a[1] . " " . $a[2];
        readingsSingleUpdate( $hash, "upnp", $a[2], 1 )
           if ( !defined($hash->{READINGS}{upnp}{VAL}) ||
                $hash->{READINGS}{upnp}{VAL} ne $a[2] );
    }

    # return usage hint
    else {
        return $usage;
    }

    return;
}

###################################
sub BRAVIA_Define($$) {
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );
    my $name = $hash->{NAME};

    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_Define()";

    if ( int(@a) < 3 ) {
        my $msg =
          "Wrong syntax: define <name> BRAVIA <ip-or-hostname> [<poll-interval>]";
        Log3 $name, 4, $msg;
        return $msg;
    }

    $hash->{TYPE} = "BRAVIA";

    my $address = $a[2];
    $hash->{helper}{ADDRESS} = $address;

    # use interval of 45 sec if not defined
    my $interval = $a[3] || 45;
    $hash->{INTERVAL} = $interval;

    $hash->{helper}{PORT} = {
        'IRCC'    => "80",
        'SERVICE' => "80",
        'UPNP'    => "52323",
    };
    
    $hash->{helper}{HEADER} = 'X-CERS-DEVICE-ID: fhem_remote';
    
    $hash->{name} = $hash->{READINGS}{name}{VAL}
      if ( defined( $hash->{READINGS}{name}{VAL} ) );

    $hash->{modelName} = $hash->{READINGS}{modelName}{VAL}
      if ( defined( $hash->{READINGS}{modelName}{VAL} ) );

    $hash->{generation} = $hash->{READINGS}{generation}{VAL}
      if ( defined( $hash->{READINGS}{generation}{VAL} ) );

    unless ( defined( AttrVal( $name, "webCmd", undef ) ) ) {
        $attr{$name}{webCmd} = 'volume:channelUp:channelDown';
    }
    unless ( defined( AttrVal( $name, "devStateIcon", undef ) ) ) {
        $attr{$name}{devStateIcon} =
          'on:rc_GREEN:off off:rc_YELLOW:on absent:rc_STOP:on';
    }
    unless ( defined( AttrVal( $name, "icon", undef ) ) ) {
        $attr{$name}{icon} = 'it_television';
    }

    # start the status update timer
    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday() + 2, "BRAVIA_GetStatus", $hash, 1 );

    return;
}

############################################################################################################
#
#   Begin of helper functions
#
############################################################################################################

###################################
sub BRAVIA_SendCommand($$;$$) {
    my ( $hash, $service, $cmd, $type ) = @_;
    my $name        = $hash->{NAME};
    my $address     = $hash->{helper}{ADDRESS};
    my $port        = $hash->{helper}{PORT};
    my $header      = $hash->{helper}{HEADER};
    my $timestamp   = gettimeofday();
    my $data;
    my $timeout;

    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_SendCommand()";

    my $URL;
    my $response;
    my $return;
    my $requestFormat = ReadingsVal($name, "requestFormat", "");

    BRAVIA_CheckRegistration($hash) if ($service ne "register" && $service ne "getStatus");

    if ( !defined($cmd) ) {
        Log3 $name, 4, "BRAVIA $name: REQ $service";
    }
    else {
        Log3 $name, 4, "BRAVIA $name: REQ $service/" . urlDecode($cmd);
    }

    $URL = "http://" . $address . ":";
    $header .= "\r\nCookie: auth=".ReadingsVal($name, "authCookie", "")
        if (ReadingsVal($name, "authCookie", "") ne "");
    if ($service eq "ircc") {
      $URL .= $port->{IRCC};
      $URL .= "/sony"
          if ($requestFormat eq "json");
      $URL .= "/IRCC";
      $header .= "\r\nSoapaction: \"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"";
      $header .= "\r\nContent-Type: text/xml; charset=UTF-8";
      $cmd = BRAVIA_GetRemotecontrolCommand($cmd);
      $data = BRAVIA_GetIrccRequest($cmd);
    } elsif ($service eq "upnp") {
      my $value;
      if ($cmd =~ m/^(.+):(\d+)$/) {
        $cmd = $1;
        $value = $2;
      }
      $URL .= $port->{UPNP};
      $URL .= "/upnp/control/RenderingControl";
      $header .= "\r\nSoapaction: \"urn:schemas-upnp-org:service:RenderingControl:1#";
      $header .= ucfirst($cmd);
      $header .= "\"";
      $header .= "\r\nContent-Type: text/xml";
      $data = BRAVIA_GetUpnpRequest($cmd, $value);
    } elsif ($service eq "register") {
      my $id = "Fhem Remote";
      my $device = "fhem_remote";
      $URL .= $port->{SERVICE};
      if ($requestFormat eq "json") {
        my $uuid = ReadingsVal($name, "registrationUUID", "");
        if (defined($cmd) && $uuid ne "") {
          if ($cmd ne "renew") {
            $header = "Authorization: Basic ";
            $header .= encode_base64(":".$cmd,"");
          }
        } else {
          undef $header;
          $uuid = createUniqueId();
          readingsSingleUpdate($hash, "registrationUUID", $uuid, 1);
        }
        $URL .= "/sony/accessControl";
        $data = "{\"method\":\"actRegister\",\"params\":[{";
        $data .= "\"clientid\":\"".$id.":".$uuid."\",";
        $data .= "\"nickname\":\"".$id." (".$device.")\",";
        $data .= "\"level\":\"private\"},";
        $data .= "[{\"value\":\"yes\",\"function\":\"WOL\"}]],\"id\":8,\"version\":\"1.0\"}";
      } else {
        $URL .= "/cers/api/register?name=".urlEncode($id)."&registrAtionType=initial&deviceId=".$device;
      }
    } elsif ($service eq "getStatus") {
      $URL .= $port->{SERVICE};
      if ($cmd eq "xml") {
        $URL .= "/cers/api/" . $service;
      } else {
        $URL .= "/sony/system";
        $data = "{\"method\":\"getPowerStatus\",\"params\":[\"\"],\"id\":1,\"version\":\"1.0\"}";
      }
    } elsif ($service eq "getContentInformation") {
      $URL .= $port->{SERVICE};
      if ($requestFormat eq "json") {
        $URL .= "/sony/avContent";
        $data = "{\"method\":\"getPlayingContentInfo\",\"params\":[\"\"],\"id\":1,\"version\":\"1.0\"}";
      } else {
        $URL .= "/cersEx/api/" . $service;
      }
    } elsif ($service eq "getContentList") {
      $URL .= $port->{SERVICE};
      if ($requestFormat eq "json") {
        $URL .= "/sony/avContent";
        $data = "{\"method\":\"getContentList\",\"params\":[{\"source\":\"" . $cmd . "\",\"type\":\"\",\"cnt\":50,\"stIdx\":\"\"}],\"id\":1,\"version\":\"1.2\"}";
      }
    } elsif ($service eq "getScheduleList") {
      $URL .= $port->{SERVICE};
      if ($requestFormat eq "json") {
        $URL .= "/sony/recording";
        $data = "{\"method\":\"getScheduleList\",\"params\":[{\"cnt\":100,\"stIdx\":0}],\"id\":1,\"version\":\"1.0\"}";
      } else {
        $URL .= "/cersEx/api/" . $service;
      }
    } else {
      $URL .= $port->{SERVICE};
      if ($requestFormat eq "json") {
        $URL .= "/sony/system";
        $data = "{\"method\":\"".$service."\",\"params\":[\"\"],\"id\":1,\"version\":\"1.0\"}";
      } else {
        $URL .= "/cers";
        if ($service =~ /^Mute.*$/) {
          $URL .= "/command/".$service;
        } else {
          $URL .= "/api/" . $service;
        }
      }
    }

    if ( defined( $attr{$name}{timeout} ) && $attr{$name}{timeout} =~ /^\d+$/ ) {
      $timeout = $attr{$name}{timeout};
    } elsif ( $service eq "getStatus" ) {
      $timeout = 7;
    } else {
      $timeout = 30;
    }

    # send request via HTTP-POST method
    Log3 $name, 5, "BRAVIA $name: POST " . $URL . " (" . urlDecode($data) . ")"
      if ( defined($data) );
    Log3 $name, 5, "BRAVIA $name: GET " . $URL
      if ( !defined($data) );
    Log3 $name, 5, "BRAVIA $name: header " . $header
      if ( defined($header) );

    if ( defined($type) && $type eq "blocking" ) {
      my ($err, $data) = HttpUtils_BlockingGet(
          {
              url         => $URL,
              timeout     => 4,
              noshutdown  => 1,
              header      => $header,
              data        => $data,
              hash        => $hash,
              service     => $service,
              cmd         => $cmd,
              type        => $type,
              timestamp   => $timestamp,
          }
      );
      Log3 $name, 5, "BRAVIA $name: REQ $service received err: $err data: $data ";
      sleep 1;
    } else {
      HttpUtils_NonblockingGet(
          {
              url         => $URL,
              timeout     => $timeout,
              noshutdown  => 1,
              header      => $header,
              data        => $data,
              hash        => $hash,
              service     => $service,
              cmd         => $cmd,
              type        => $type,
              timestamp   => $timestamp,
              callback    => \&BRAVIA_ReceiveCommand,
          }
      );
    }

    return;
}

###################################
sub BRAVIA_ReceiveCommand($$$) {
    my ( $param, $err, $data ) = @_;
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $service = $param->{service};
    my $cmd     = $param->{cmd};

    my $newstate;
    my $rc = ( $param->{buf} ) ? $param->{buf} : $param;
    my $return;
    
    my %mon2num = qw(
        jan 1  feb 2  mar 3  apr 4  may 5  jun 6
        jul 7  aug 8  sep 9  oct 10 nov 11 dec 12
    );
    
    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_ReceiveCommand() rc: $rc err: $err data: $data ";

    readingsBeginUpdate($hash);

    # device not reachable
    if ($err) {

        if ( !defined($cmd) || ref($cmd) eq "HASH" || $cmd eq "" ) {
            Log3 $name, 4, "BRAVIA $name: RCV TIMEOUT $service";
        }
        else {
            Log3 $name, 4,
              "BRAVIA $name: RCV TIMEOUT $service/" . urlDecode($cmd);
        }

        # device is not reachable or
        # does not even support master command for status
        if ( $service eq "getStatus" ) {
            BRAVIA_ClearContentInformation($hash);
            $newstate = "absent";

            if (
                ( !defined( $hash->{helper}{AVAILABLE} ) )
                or ( defined( $hash->{helper}{AVAILABLE} )
                    and $hash->{helper}{AVAILABLE} eq 1 )
              )
            {
                $hash->{helper}{AVAILABLE} = 0;
                readingsBulkUpdate( $hash, "presence", "absent" );
            }
        }

        # device behaves naughty
        else {
            $newstate = "on";

            Log3 $name, 3,
                "BRAVIA $name: API command '".$service."' not supported by device.";
        }
    }

    # data received
    elsif ($data) {
      
        if (
            ( !defined( $hash->{helper}{AVAILABLE} ) )
            or ( defined( $hash->{helper}{AVAILABLE} )
                and $hash->{helper}{AVAILABLE} eq 0 )
          )
        {
            $hash->{helper}{AVAILABLE} = 1;
            readingsBulkUpdate( $hash, "presence", "present" );
        }

        if ( !defined($cmd) ) {
            Log3 $name, 4, "BRAVIA $name: RCV $service";
        }
        else {
            Log3 $name, 4, "BRAVIA $name: RCV $service/" . urlDecode($cmd);
        }

        if ( $data ne "" ) {
            if ( $data =~ /^<\?xml/ ) {
                my $parser = XML::Simple->new(
                    NormaliseSpace => 2,
                    KeepRoot       => 0,
                    ForceArray     => 0,
                    SuppressEmpty  => 1
                );

                if ( !defined($cmd) || ref($cmd) eq "HASH" || $cmd eq "" ) {
                    Log3 $name, 4, "BRAVIA $name: RES $service - $data";
                }
                else {
                    Log3 $name, 4,
                      "BRAVIA $name: RES $service/" . urlDecode($cmd) . " - $data";
                }

                readingsBulkUpdate( $hash, "requestFormat", "xml" )
                  if ( $service eq "getStatus" && ReadingsVal($name , "requestFormat", "") eq "" );

                $return = $parser->XMLin( Encode::encode_utf8($data) );
            }

            elsif ( $data =~ /^{/ || $data =~ /^\[/ ) {
                 if ( !defined($cmd) || ref($cmd) eq "HASH" || $cmd eq "" ) {
                    Log3 $name, 4, "BRAVIA $name: RES $service - $data";
                }
                else {
                    Log3 $name, 4,
                      "BRAVIA $name: RES $service/" . urlDecode($cmd) . " - $data";
                }

                readingsBulkUpdate( $hash, "requestFormat", "json" )
                  if ( $service eq "getStatus" && ReadingsVal($name , "requestFormat", "") eq "" );

                $return = decode_json( Encode::encode_utf8($data) );
            }

            elsif ( $data eq "<html><head><title>not found</title></head><body>not found</body></html>" ) {
                if ( !defined($cmd) || ref($cmd) eq "HASH" || $cmd eq "" ) {
                    Log3 $name, 4, "BRAVIA $name: RES $service - not found";
                }
                else {
                    Log3 $name, 4,
                      "BRAVIA $name: RES $service/" . urlDecode($cmd) . " - not found";
                }

                $return = "not found";
            }

            elsif ( $data =~ /^<s:Envelope/ ) {
                if ( !defined($cmd) ) {
                    Log3 $name, 4, "BRAVIA $name: RES $service - response";
                }
                else {
                    Log3 $name, 4,
                      "BRAVIA $name: RES $service/" . urlDecode($cmd) . " - response";
                }

                $return = "ok";
            }

            else {
                if ( !defined($cmd) || ref($cmd) eq "HASH" || $cmd eq "" ) {
                    Log3 $name, 5, "BRAVIA $name: RES ERROR $service\n" . $data;
                }
                else {
                    Log3 $name, 5,
                        "BRAVIA $name: RES ERROR $service/"
                      . urlDecode($cmd) . "\n"
                      . $data;
                }

                return undef;
            }
        }

        $newstate = BRAVIA_ProcessCommandData( $param, $return );
    }

    if ( defined( $newstate ) ) {

      # Set reading for power
      #
      my $readingPower = "off";
      if ( $newstate eq "on" ) {
          $readingPower = "on";
      }
      if ( ReadingsVal($name, "power", "") ne $readingPower )
      {
          readingsBulkUpdate( $hash, "power", $readingPower );
      }
  
      # Set reading for state
      #
      if ( ReadingsVal($name, "state", "") ne $newstate )
      {
          readingsBulkUpdate( $hash, "state", $newstate );
      }
  
      # Set BRAVIA online-only readings to "-"
      # in case box is not reachable
      if (   $newstate eq "absent"
          || $newstate eq "undefined" )
      {
          foreach ( 'input', ) {
            if ( ReadingsVal($name, $_, "-") ne "-" ) {
              readingsBulkUpdate( $hash, $_, "-" );
            }
          }
      }
    }

    readingsEndUpdate( $hash, 1 );

    return;
}

###################################
sub BRAVIA_Undefine($$) {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, "BRAVIA $name: called function BRAVIA_Undefine()";

    # Stop the internal GetStatus-Loop and exit
    RemoveInternalTimer($hash);

    return;
}

###################################
sub BRAVIA_wake ($$) {
    my ( $name, $mac_addr ) = @_;
    my $address = '255.255.255.255';
    my $port = 9;

    my $sock = new IO::Socket::INET( Proto => 'udp' )
      or die "socket : $!";
    die "Can't create WOL socket" if ( !$sock );

    my $ip_addr = inet_aton($address);
    my $sock_addr = sockaddr_in( $port, $ip_addr );
    $mac_addr =~ s/://g;
    my $packet =
      pack( 'C6H*', 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, $mac_addr x 16 );

    setsockopt( $sock, SOL_SOCKET, SO_BROADCAST, 1 )
      or die "setsockopt : $!";

    Log3 $name, 4,
      "BRAVIA $name: Waking up by sending Wake-On-Lan magic package to "
      . $mac_addr;
    send( $sock, $packet, 0, $sock_addr ) or die "send : $!";
    close($sock);

    return;
}

###################################
# process return data
sub BRAVIA_ProcessCommandData ($$) {

    my ($param, $return) = @_;
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $service = $param->{service};
    my $cmd     = $param->{cmd};
    my $type    = ( $param->{type} ) ? $param->{type} : "";
    my $header  = $param->{httpheader};
    my $newstate;
  
    # ircc
    if ( $service eq "ircc" ) {
        if ( ref($return) ne "HASH" && $return eq "ok" ) {
    
            # toggle standby
            if ( defined($type) && $type eq "off" ) {
                $newstate = "off";
            }
    
            # toggle standby
            elsif ( defined($type) && $type eq "on" ) {
                $newstate = "on";
            }
    
        }
    }
    
    # upnp
    elsif ( $service eq "upnp" ) {
      if ( ref($return) eq "HASH" ) {
        if ( $cmd eq "getVolume" ) {
          my $volume = $return->{"s:Body"}{"u:GetVolumeResponse"}{CurrentVolume};
          if ( defined( $volume ) ) {
            readingsBulkUpdate( $hash, "volume", $volume )
                if (ReadingsVal($name, "volume", "-1") ne $volume);
          }
        } elsif ( $cmd eq "getMute" ) {
          my $mute = $return->{"s:Body"}{"u:GetMuteResponse"}{CurrentMute} eq "0" ? "off" : "on";
          if ( defined( $mute ) ) {
            readingsBulkUpdate( $hash, "mute", $mute )
                if (ReadingsVal($name, "mute", "-1") ne $mute);
          }
        }
      }
    }
    
    # getStatus
    elsif ( $service eq "getStatus" ) {
      my $input = "-";
      my $setInput;
    
      my %statusKeys;
      foreach ( keys %{ $hash->{READINGS} } ) {
        $statusKeys{$_} = 1 if ( $_ =~ /^s_.*/ && ReadingsVal($name, $_, "") ne "-" );
      }
      if ( ref($return) eq "HASH" ) {
        if ( ref($return->{status}{statusItem}) eq "ARRAY" ) {
          foreach ( @{ $return->{status}{statusItem} } ) {
            if ( $_->{field} eq "source" ) {
              $input = $_->{value};
              $setInput = "true";
            } else {
              readingsBulkUpdate( $hash, "s_".$_->{field}, $_->{value} )
                  if (ReadingsVal($name, "s_".$_->{field}, "") ne $_->{value} );
            }
            delete $statusKeys{"s_".$_->{field}};
          }
        } elsif (defined($return->{status}{statusItem}{field})) {
          my $field = "s_".$return->{status}{statusItem}{field};
          if ( defined($field) && $field ne "" ) {
            if ( $field eq "s_source" ) {
              $input = $return->{status}{statusItem}{value};
              $setInput = "true";
            } else {
              readingsBulkUpdate( $hash, $field, $return->{status}{statusItem}{value} )
                  if (ReadingsVal($name, $field, "") ne $return->{status}{statusItem}{value} );
            }
            delete $statusKeys{$field};
          }
        }
      }
    
      readingsBulkUpdate( $hash, "input", $input )
          if ( defined($setInput) and
              (ReadingsVal($name, "input", "") ne $input) );
    
      #remove outdated content information - replaces by "-"
      foreach ( keys %statusKeys ) {
        readingsBulkUpdate( $hash, $_, "-" );
      }
      
      # check for valid status
      if (ref $return eq ref {} && ref($return->{error}) eq "ARRAY" && $return->{error}[0] eq "404") {
        BRAVIA_ClearContentInformation($hash);
        return "off";
      }
  
    
      # fetch other info
    
      # read system information if not existing
      BRAVIA_SendCommand( $hash, "getSystemInformation" )
          if ( ReadingsVal($name, "name", "0") eq "0" );
    
      # read content information
      if ( ReadingsVal($name, "generation", "1.0") ne "1.0" ) {
        if (ref $return eq ref {} && ref($return->{result}) eq "ARRAY" && $return->{result}[0]{status} ne "active") {
          # current status is not active, don't need to fetch content information
          BRAVIA_ClearContentInformation($hash);
          $newstate = "off";              
        } else {
          BRAVIA_SendCommand( $hash, "getContentInformation" );
        }
      } elsif (ref $return eq ref {}) {
        if (ref($return->{result}) eq "ARRAY") {
          $newstate = ( $return->{result}[0]{status} eq "active" ? "on" : $return->{result}[0]{status} );
        } else {
          $newstate = ( $return->{status}{name} eq "viewing" ? "on" : $return->{status}{name} );
        }
        # get current system settings
        if ($newstate eq "on" && ReadingsVal($name, "upnp", "") eq "on") {
          BRAVIA_SendCommand( $hash, "upnp", "getVolume" );
          BRAVIA_SendCommand( $hash, "upnp", "getMute" );
        }
      }
    }
    
    # getSystemInformation
    elsif ( $service eq "getSystemInformation" ) {
      if ( ref($return) eq "HASH" ) {
        if (ref($return->{result}) eq "ARRAY") {
          my $sysInfo = $return->{result}[0];
          readingsBulkUpdate( $hash, "name", $sysInfo->{name} );
          readingsBulkUpdate( $hash, "generation", $sysInfo->{generation} );
          readingsBulkUpdate( $hash, "area", $sysInfo->{area} );
          readingsBulkUpdate( $hash, "language", $sysInfo->{language} );
          readingsBulkUpdate( $hash, "country", $sysInfo->{region} );
          readingsBulkUpdate( $hash, "modelName", $sysInfo->{model} );
          readingsBulkUpdate( $hash, "macAddr", $sysInfo->{macAddr} );
          $hash->{name} = $sysInfo->{name};
          $hash->{modelName} = $sysInfo->{model};
          $hash->{generation} = $sysInfo->{generation};
        } else {
          readingsBulkUpdate( $hash, "name", $return->{name} );
          readingsBulkUpdate( $hash, "generation", $return->{generation} );
          readingsBulkUpdate( $hash, "area", $return->{area} );
          readingsBulkUpdate( $hash, "language", $return->{language} );
          readingsBulkUpdate( $hash, "country", $return->{country} );
          readingsBulkUpdate( $hash, "modelName", $return->{modelName} );
          $hash->{name} = $return->{name};
          $hash->{modelName} = $return->{modelName};
          $hash->{generation} = $return->{generation};
        }
      }
    }
    
    # getContentInformation
    elsif ( $service eq "getContentInformation" ) {
      my %contentKeys;
      my $channelName = "-";
      my $channelNo = "-";
      my $currentTitle = "-";
      my $currentMedia = "-";
      foreach ( keys %{ $hash->{READINGS} } ) {
        $contentKeys{$_} = 1
            if ( $_ =~ /^ci_.*/ and ReadingsVal($name, $_, "") ne "-" );
      }
      if ( ref($return) eq "HASH" ) {
        $newstate = "on";
        if ( defined($return->{infoItem}) ) {
          # xml
          if ( ref($return->{infoItem}) eq "ARRAY" ) {
            foreach ( @{ $return->{infoItem} } ) {
              if ( $_->{field} eq "displayNumber" ) {
                $channelNo = $_->{value};
              } elsif ( $_->{field} eq "inputType" ) {
                $currentMedia = $_->{value};
              } elsif ( $_->{field} eq "serviceName" ) {
                $channelName = $_->{value};
                $channelName =~ s/^\s+//;
                $channelName =~ s/\s+$//;
                $channelName =~ s/\s/_/g;
                $channelName =~ s/,/./g;
              } elsif ( $_->{field} eq "title" ) {
                $currentTitle = Encode::decode_utf8($_->{value});
              } else {
                readingsBulkUpdate( $hash, "ci_".$_->{field}, $_->{value} )
                    if ( ReadingsVal($name, "ci_".$_->{field}, "") ne $_->{value} );
                delete $contentKeys{"ci_".$_->{field}};
              }
            }
          } else {
            my $field = "ci_".$return->{infoItem}->{field};
            my $value = $return->{infoItem}->{value};
            readingsBulkUpdate( $hash, $field, $value )
                if ( ReadingsVal($name, $field, "") ne $value );
            delete $contentKeys{$field};
          }
        } else {
          # json
          if ( ref($return->{result}[0]) eq "HASH" ) {
            foreach ( keys %{$return->{result}[0]} ) {
              if ( $_ eq "dispNum" ) {
                $channelNo = $return->{result}[0]{$_};
              } elsif ( $_ eq "programMediaType" ) {
                $currentMedia = $return->{result}[0]{$_};
              } elsif ( $_ eq "title" ) {
                $channelName = $return->{result}[0]{$_};
                $channelName =~ s/^\s+//;
                $channelName =~ s/\s+$//;
                $channelName =~ s/\s/_/g;
                $channelName =~ s/,/./g;
              } elsif ( $_ eq "programTitle" ) {
                $currentTitle = Encode::decode_utf8($return->{result}[0]{$_});
              } elsif ( $_ eq "source" ) {
                readingsBulkUpdate( $hash, "input", $return->{result}[0]{$_} )
                    if ( ReadingsVal($name, "input", "") ne $return->{result}[0]{$_} );
              } else {
                readingsBulkUpdate( $hash, "ci_".$_, $return->{result}[0]{$_} )
                    if ( ReadingsVal($name, "ci_".$_, "") ne $return->{result}[0]{$_} );
                delete $contentKeys{"ci_".$_};
              }
            }
          } elsif ( ref($return->{error}) eq "ARRAY" && $return->{error}[0] eq "7" && $return->{error}[1] eq "Illegal State" ) {
              #could be timeshift mode
              BRAVIA_SendCommand( $hash, "getScheduleList" );
              return;
          }          
        }
      } else {
        if ( ReadingsVal($name, "input", "") eq "Others" || ReadingsVal($name, "input", "") eq "Broadcast" ) {
          $newstate = "off";
        } else {
          $newstate = "on";
        }
      }
      readingsBulkUpdate( $hash, "channel", $channelName )
          if ( ReadingsVal($name, "channel", "") ne $channelName );
      readingsBulkUpdate( $hash, "channelId", $channelNo )
          if ( ReadingsVal($name, "channelId", "") ne $channelNo );
      readingsBulkUpdate( $hash, "currentTitle", $currentTitle )
          if ( ReadingsVal($name, "currentTitle", "") ne $currentTitle );
      readingsBulkUpdate( $hash, "currentMedia", $currentMedia )
          if ( ReadingsVal($name, "currentMedia", "") ne $currentMedia );
    
      if ($channelName ne "-" && $channelNo ne "-") {
        BRAVIA_SendCommand( $hash, "getContentList", ReadingsVal($name, "input", "") )
          if (ReadingsVal($name, "requestFormat", "") eq "json" && !defined($hash->{helper}{device}{channelPreset}{ $channelNo }));
        $hash->{helper}{device}{channelPreset}{ $channelNo }{id} = $channelNo;
        $hash->{helper}{device}{channelPreset}{ $channelNo }{name} = $channelName;
      }
    
      #remove outdated content information - replaces by "-"
      foreach ( keys %contentKeys ) {
        readingsBulkUpdate( $hash, $_, "-" );
      }
    
      # get current system settings
      if ($newstate eq "on" && (ReadingsVal($name, "upnp", "") eq "on")) {
        BRAVIA_SendCommand( $hash, "upnp", "getVolume" );
        BRAVIA_SendCommand( $hash, "upnp", "getMute" );
      }
    }
    
    # getScheduleList
    elsif ( $service eq "getScheduleList" ) {
      my %contentKeys;
      my $channelName = "-";
      my $currentTitle = "-";
      my $currentMedia = "-";
      foreach ( keys %{ $hash->{READINGS} } ) {
        $contentKeys{$_} = 1
            if ( $_ =~ /^ci_.*/ and ReadingsVal($name, $_, "") ne "-" );
      }
      if ( ref($return) eq "HASH" ) {
        if (ref($return->{result}) eq "ARRAY") {
          $newstate = "on";
          foreach ( @{ $return->{result} } ) {
            foreach ( @{ $_ } ) {
              if ($_->{recordingStatus} eq "recording") {
                my $key;
                foreach $key ( keys %{ $_ }) {
                  if ( $key eq "type" ) {
                    $currentMedia = $_->{$key};
                    readingsBulkUpdate( $hash, "input", $_->{$key} )
                        if ( ReadingsVal($name, "input", "") ne $_->{$key} );
                  } elsif ( $key eq "channelName" ) {
                    $channelName = $_->{$key};
                    $channelName =~ s/^\s+//;
                    $channelName =~ s/\s+$//;
                    $channelName =~ s/\s/_/g;
                    $channelName =~ s/,/./g;
                  } elsif ( $key eq "title" ) {
                    $currentTitle = Encode::decode_utf8($_->{$key});
                  } else {
                    readingsBulkUpdate( $hash, "ci_".$key, $_->{$key} )
                        if ( ReadingsVal($name, "ci_".$key, "") ne $_->{$key} );
                    delete $contentKeys{"ci_".$key};
                  }
                }
              }
            }
          }
        }
      }
      readingsBulkUpdate( $hash, "channel", $channelName )
          if ( ReadingsVal($name, "channel", "") ne $channelName );
      readingsBulkUpdate( $hash, "currentTitle", $currentTitle )
          if ( ReadingsVal($name, "currentTitle", "") ne $currentTitle );
      readingsBulkUpdate( $hash, "currentMedia", $currentMedia )
          if ( ReadingsVal($name, "currentMedia", "") ne $currentMedia );
    
      #remove outdated content information - replaces by "-"
      foreach ( keys %contentKeys ) {
        readingsBulkUpdate( $hash, $_, "-" );
      }

      # get current system settings
      if (ReadingsVal($name, "upnp", "") eq "on") {
        BRAVIA_SendCommand( $hash, "upnp", "getVolume" );
        BRAVIA_SendCommand( $hash, "upnp", "getMute" );
      }
    }

    # getContentList
    elsif ( $service eq "getContentList" ) {
      if ( ref($return) eq "HASH" ) {
        if (ref($return->{result}) eq "ARRAY") {
          foreach ( @{ $return->{result} } ) {
            foreach ( @{ $_ } ) {
              my $channelNo;
              my $channelName;
              my $key;
              foreach $key ( keys %{ $_ }) {
                if ( $key eq "dispNum" ) {
                  $channelNo = $_->{$key};
                } elsif ( $key eq "title" ) {
                  $channelName = $_->{$key};
                  $channelName =~ s/^\s+//;
                  $channelName =~ s/\s+$//;
                  $channelName =~ s/\s/_/g;
                  $channelName =~ s/,/./g;
                }
              }
              $hash->{helper}{device}{channelPreset}{ $channelNo }{id} = $channelNo;
              $hash->{helper}{device}{channelPreset}{ $channelNo }{name} = $channelName;
            }
          }
        }
      }
    }

    # register
    elsif ( $service eq "register" ) {
      if ( $header =~ /auth=([A-Za-z0-9]+)/ ) {
        readingsBulkUpdate( $hash, "authCookie", $1 );
      }
      if ( $header =~ /expires=\w{3}, (\d{2}-\w{3}-\d{4} [0-2]\d:[0-5]\d:[0-5]\d)/ ) {
        readingsBulkUpdate( $hash, "authExpires", $1 );
      }
      if ( $header =~ /Expires=\w{2}., (\d{2}) (\w{3}). (\d{4}) ([0-2]\d:[0-5]\d:[0-5]\d)/ ) {
        readingsBulkUpdate( $hash, "authExpires", $1."-".$2."-".$3." ".$4 );
      }
    }
    
    # all other command results
    else {
        Log3 $name, 2, "BRAVIA $name: ERROR: method to handle response of $service not implemented";
    }
    
    return $newstate;

}

#####################################
sub BRAVIA_ClearContentInformation ($) {

    my ($hash)    = @_;
    my $name    = $hash->{NAME};

    #remove outdated content information - replaces by "-"
    foreach ( keys %{ $hash->{READINGS} } ) {
      readingsBulkUpdate($hash, $_, "-")
          if ( $_ =~ /^ci_.*/ and ReadingsVal($name, $_, "") ne "-" );
    }

    readingsBulkUpdate( $hash, "channel", "-" )
        if ( ReadingsVal($name, "channel", "") ne "-" );
    readingsBulkUpdate( $hash, "channelId", "-" )
        if ( ReadingsVal($name, "channelId", "") ne "-" );
    readingsBulkUpdate( $hash, "currentTitle", "-" )
        if ( ReadingsVal($name, "currentTitle", "") ne "-" );
    readingsBulkUpdate( $hash, "currentMedia", "-" )
        if ( ReadingsVal($name, "currentMedia", "") ne "-" );
    readingsBulkUpdate( $hash, "input", "-" )
        if ( ReadingsVal($name, "input", "") ne "-" );

}


#####################################
# Callback from 95_remotecontrol for command makenotify.
sub BRAVIA_RCmakenotify($$) {
    my ( $nam, $ndev ) = @_;
    my $nname = "notify_$nam";

    fhem( "define $nname notify $nam set $ndev remoteControl " . '$EVENT', 1 );
    Log3 undef, 2, "[remotecontrol:BRAVIA] Notify created: $nname";
    return "Notify created by BRAVIA: $nname";
}

#####################################
# RC layouts

# Sony TV with SVG
sub BRAVIA_RClayout_SVG() {
    my @row;

    $row[0] = "SOURCE:rc_AV.svg,:rc_BLANK.svg,:rc_BLANK.svg,POWER:rc_POWER.svg";
    $row[1] = "TVPAUSE:rc_TVstop.svg,ASPECT,MODE3D,TRACKID";
    $row[2] = "PREVIOUS:rc_PREVIOUS.svg,REWIND:rc_REW.svg,FORWARD:rc_FF.svg,NEXT:rc_NEXT.svg";
    $row[3] = "REC:rc_REC.svg,PLAY:rc_PLAY.svg,PAUSE:rc_PAUSE.svg,STOP:rc_STOP.svg";
    $row[4] = "RED:rc_RED.svg,GREEN:rc_GREEN.svg,YELLOW:rc_YELLOW.svg,BLUE:rc_BLUE.svg";
    $row[5] = ":rc_BLANK.svg,:rc_BLANK.svg,:rc_BLANK.svg";

    $row[6] = "HELP:rc_HELP.svg,SEN,SYNCMENU";
    $row[7] = "GUIDE:rc_MENU.svg,UP:rc_UP.svg,INFO:rc_INFO.svg";
    $row[8] = "LEFT:rc_LEFT.svg,OK:rc_OK.svg,RIGHT:rc_RIGHT.svg";
    $row[9] = "RETURN:rc_BACK.svg,DOWN:rc_DOWN.svg,OPTIONS:rc_OPTIONS.svg,HOMEtxt";
    $row[10] = ":rc_BLANK.svg,:rc_BLANK.svg,:rc_BLANK.svg";

    $row[11] = "DIGITAL,EXIT:rc_EXIT.svg,TV:rc_TV.svg";
    $row[12] = "1:rc_1.svg,2:rc_2.svg,3:rc_3.svg";
    $row[13] = "4:rc_4.svg,5:rc_5.svg,6:rc_6.svg";
    $row[14] = "7:rc_7.svg,8:rc_8.svg,9:rc_9.svg";
    $row[15] = "TEXT:rc_TEXT.svg,0:rc_0.svg,SUBTITLE";
    $row[16] = ":rc_BLANK.svg,:rc_BLANK.svg,:rc_BLANK.svg";

    $row[17] = "MUTE:rc_MUTE.svg,VOLUP:rc_VOLPLUS.svg,CHANNELUP:rc_UP.svg,AUDIO:rc_AUDIO.svg";
    $row[18] = ":rc_BLANK.svg,VOLDOWN:rc_VOLMINUS.svg,CHANNELDOWN:rc_DOWN.svg";

    $row[19] = "attr rc_iconpath icons";
    $row[20] = "attr rc_iconprefix rc_";
    return @row;
}

# Sony TV with PNG
sub BRAVIA_RClayout() {
    my @row;

    $row[0] = "SOURCE,:blank,:blank,POWER:POWEROFF";
    $row[1] = "TVPAUSE:TVstop,ASPECT,MODE3D,TRACKID";
    $row[2] = "PREVIOUS,REWIND,FORWARD:FF,NEXT";
    $row[3] = "REC,PLAY,PAUSE,STOP";
    $row[4] = "RED,GREEN,YELLOW,BLUE";
    $row[5] = ":blank,:blank,:blank";

    $row[6] = "HELP,SEN,SYNCMENU";
    $row[7] = "GUIDE,UP,INFO";
    $row[8] = "LEFT,OK,RIGHT";
    $row[9] = "RETURN,DOWN,OPTIONS:SUBMENU,HOMEtxt";
    $row[10] = ":blank,:blank,:blank";

    $row[11] = "DIGITAL,EXIT,TV";
    $row[12] = "1,2,3";
    $row[13] = "4,5,6";
    $row[14] = "7,8,9";
    $row[15] = "TEXT,0,SUBTITLE";
    $row[16] = ":blank,:blank,:blank";

    $row[17] = "MUTE,VOLUP:VOLUP2,CHANNELUP:CHUP2,AUDIO";
    $row[18] = ":blank,VOLDOWN:VOLDOWN2,CHANNELDOWN:CHDOWN2";
    return @row;
}

###################################
#    <command name="Confirm" type="ircc" value="AAAAAQAAAAEAAABlAw==" />
#    <command name="Up" type="ircc" value="AAAAAQAAAAEAAAB0Aw==" />
#    <command name="Down" type="ircc" value="AAAAAQAAAAEAAAB1Aw==" />
#    <command name="Right" type="ircc" value="AAAAAQAAAAEAAAAzAw==" />
#    <command name="Left" type="ircc" value="AAAAAQAAAAEAAAA0Aw==" />
#    <command name="Home" type="ircc" value="AAAAAQAAAAEAAABgAw==" />
#    <command name="Options" type="ircc" value="AAAAAgAAAJcAAAA2Aw==" />
#    <command name="Return" type="ircc" value="AAAAAgAAAJcAAAAjAw==" />
#    <command name="Num1" type="ircc" value="AAAAAQAAAAEAAAAAAw==" />
#    <command name="Num2" type="ircc" value="AAAAAQAAAAEAAAABAw==" />
#    <command name="Num3" type="ircc" value="AAAAAQAAAAEAAAACAw==" />
#    <command name="Num4" type="ircc" value="AAAAAQAAAAEAAAADAw==" />
#    <command name="Num5" type="ircc" value="AAAAAQAAAAEAAAAEAw==" />
#    <command name="Num6" type="ircc" value="AAAAAQAAAAEAAAAFAw==" />
#    <command name="Num7" type="ircc" value="AAAAAQAAAAEAAAAGAw==" />
#    <command name="Num8" type="ircc" value="AAAAAQAAAAEAAAAHAw==" />
#    <command name="Num9" type="ircc" value="AAAAAQAAAAEAAAAIAw==" />
#    <command name="Num0" type="ircc" value="AAAAAQAAAAEAAAAJAw==" />
#    <command name="Num11" type="ircc" value="AAAAAQAAAAEAAAAKAw==" />
#    <command name="Num12" type="ircc" value="AAAAAQAAAAEAAAALAw==" />
#    <command name="Power" type="ircc" value="AAAAAQAAAAEAAAAVAw==" />
#    <command name="Display" type="ircc" value="AAAAAQAAAAEAAAA6Aw==" />
#    <command name="VolumeUp" type="ircc" value="AAAAAQAAAAEAAAASAw==" />
#    <command name="VolumeDown" type="ircc" value="AAAAAQAAAAEAAAATAw==" />
#    <command name="Mute" type="ircc" value="AAAAAQAAAAEAAAAUAw==" />
#    <command name="Audio" type="ircc" value="AAAAAQAAAAEAAAAXAw==" />
#    <command name="SubTitle" type="ircc" value="AAAAAgAAAJcAAAAoAw==" />
#    <command name="Yellow" type="ircc" value="AAAAAgAAAJcAAAAnAw==" />
#    <command name="Blue" type="ircc" value="AAAAAgAAAJcAAAAkAw==" />
#    <command name="Red" type="ircc" value="AAAAAgAAAJcAAAAlAw==" />
#    <command name="Green" type="ircc" value="AAAAAgAAAJcAAAAmAw==" />
#    <command name="Play" type="ircc" value="AAAAAgAAAJcAAAAaAw==" />
#    <command name="Stop" type="ircc" value="AAAAAgAAAJcAAAAYAw==" />
#    <command name="Pause" type="ircc" value="AAAAAgAAAJcAAAAZAw==" />
#    <command name="Rewind" type="ircc" value="AAAAAgAAAJcAAAAbAw==" />
#    <command name="Forward" type="ircc" value="AAAAAgAAAJcAAAAcAw==" />
#    <command name="Prev" type="ircc" value="AAAAAgAAAJcAAAA8Aw==" />
#    <command name="Next" type="ircc" value="AAAAAgAAAJcAAAA9Aw==" />
#    <command name="Replay" type="ircc" value="AAAAAgAAAJcAAAB5Aw==" />
#    <command name="Advance" type="ircc" value="AAAAAgAAAJcAAAB4Aw==" />
#    <command name="TopMenu" type="ircc" value="AAAAAgAAABoAAABgAw==" />
#    <command name="PopUpMenu" type="ircc" value="AAAAAgAAABoAAABhAw==" />
#    <command name="Eject" type="ircc" value="AAAAAgAAAJcAAABIAw==" />
#    <command name="Rec" type="ircc" value="AAAAAgAAAJcAAAAgAw==" />
#    <command name="SyncMenu" type="ircc" value="AAAAAgAAABoAAABYAw==" />
#    <command name="ClosedCaption" type="ircc" value="AAAAAgAAAKQAAAAQAw==" />
#    <command name="Teletext" type="ircc" value="AAAAAQAAAAEAAAA/Aw==" />
#    <command name="ChannelUp" type="ircc" value="AAAAAQAAAAEAAAAQAw==" />
#    <command name="ChannelDown" type="ircc" value="AAAAAQAAAAEAAAARAw==" />
#    <command name="Input" type="ircc" value="AAAAAQAAAAEAAAAlAw==" />
#    <command name="GGuide" type="ircc" value="AAAAAQAAAAEAAAAOAw==" />
#    <command name="EPG" type="ircc" value="AAAAAgAAAKQAAABbAw==" />
# 755   <command name="Enter" type="ircc" value="AAAAAQAAAAEAAAALAw==" />
#    <command name="DOT" type="ircc" value="AAAAAgAAAJcAAAAdAw==" />
#    <command name="Analog" type="ircc" value="AAAAAgAAAHcAAAANAw==" />
#    <command name="Exit" type="ircc" value="AAAAAQAAAAEAAABjAw==" />
# 755   <command name="*AD" type="ircc" value="AAAAAgAAABoAAAA7Aw==" />
#    <command name="Digital" type="ircc" value="AAAAAgAAAJcAAAAyAw==" />
# 755   <command name="Analog?" type="ircc" value="AAAAAgAAAJcAAAAuAw==" />
#    <command name="BS" type="ircc" value="AAAAAgAAAJcAAAAsAw==" />
#    <command name="CS" type="ircc" value="AAAAAgAAAJcAAAArAw==" />
#    <command name="BSCS" type="ircc" value="AAAAAgAAAJcAAAAQAw==" />
#    <command name="Ddata" type="ircc" value="AAAAAgAAAJcAAAAVAw==" />
# 755   <command name="SEN" type="ircc" value="AAAAAgAAABoAAAB9Aw==" />
# 755   <command name="Netflix" type="ircc" value="AAAAAgAAABoAAAB8Aw==" />
#    <command name="InternetWidgets" type="ircc" value="AAAAAgAAABoAAAB6Aw==" />
#    <command name="InternetVideo" type="ircc" value="AAAAAgAAABoAAAB5Aw==" />
#    <command name="SceneSelect" type="ircc" value="AAAAAgAAABoAAAB4Aw==" />
#    <command name="Mode3D" type="ircc" value="AAAAAgAAAHcAAABNAw==" />
#    <command name="iManual" type="ircc" value="AAAAAgAAABoAAAB7Aw==" />
#    <command name="Wide" type="ircc" value="AAAAAgAAAKQAAAA9Aw==" />
#    <command name="Jump" type="ircc" value="AAAAAQAAAAEAAAA7Aw==" />
#    <command name="PAP" type="ircc" value="AAAAAgAAAKQAAAB3Aw==" />
#    <command name="MyEPG" type="ircc" value="AAAAAgAAAHcAAABrAw==" />
#    <command name="ProgramDescription" type="ircc" value="AAAAAgAAAJcAAAAWAw==" />
#    <command name="WriteChapter" type="ircc" value="AAAAAgAAAHcAAABsAw==" />
#    <command name="TrackID" type="ircc" value="AAAAAgAAABoAAAB+Aw==" />
#    <command name="TenKey" type="ircc" value="AAAAAgAAAJcAAAAMAw==" />
#    <command name="AppliCast" type="ircc" value="AAAAAgAAABoAAABvAw==" />
#    <command name="acTVila" type="ircc" value="AAAAAgAAABoAAAByAw==" />
#    <command name="DeleteVideo" type="ircc" value="AAAAAgAAAHcAAAAfAw==" />
#    <command name="EasyStartUp" type="ircc" value="AAAAAgAAAHcAAABqAw==" />
#    <command name="OneTouchTimeRec" type="ircc" value="AAAAAgAAABoAAABkAw==" />
#    <command name="OneTouchView" type="ircc" value="AAAAAgAAABoAAABlAw==" />
#    <command name="OneTouchRec" type="ircc" value="AAAAAgAAABoAAABiAw==" />
#    <command name="OneTouchRecStop" type="ircc" value="AAAAAgAAABoAAABjAw==" />
#    <command name="Analog2" type="ircc" value="AAAAAQAAAAEAAAA4Aw==" />
# 755   <command name="Tv_Radio" type="ircc" value="AAAAAgAAABoAAABXAw==" />
# 755   <command name="PhotoFrame" type="ircc" value="AAAAAgAAABoAAABVAw==" />
# 755   <command name="TvPause" type="ircc" value="AAAAAgAAABoAAABnAw==" />
#    <command name="MuteOn" type="url" value="http://192.168.2.43:80/cers/command/MuteOn" />
#    <command name="MuteOff" type="url" value="http://192.168.2.43:80/cers/command/MuteOff" />
# 755   <command name="PowerOff" type="ircc" value="AAAAAQAAAAEAAAAvAw==" />
# 755   <command name="ZoomIn" type="url" value="http://192.168.2.43:80/cers/command/ZoomIn" />
# 755   <command name="ZoomOut" type="url" value="http://192.168.2.43:80/cers/command/ZoomOut" />
# 755   <command name="BrowserBack" type="url" value="http://192.168.2.43:80/cers/command/BrowserBack" />
# 755   <command name="BrowserForward" type="url" value="http://192.168.2.43:80/cers/command/BrowserForward" />
# 755   <command name="BrowserReload" type="url" value="http://192.168.2.43:80/cers/command/BrowserReload" />
# 755   <command name="BrowserStop" type="url" value="http://192.168.2.43:80/cers/command/BrowserStop" />
# 755   <command name="BrowserBookmarkList" type="url" value="http://192.168.2.43:80/cers/command/BrowserBookmarkList" />
sub BRAVIA_GetRemotecontrolCommand($) {
    my ($command) = @_;
    my $commands = {
        'POWER'       => "AAAAAQAAAAEAAAAVAw==",
        'STANDBY'     => "AAAAAQAAAAEAAAAvAw==",
        'EXIT'        => "AAAAAQAAAAEAAABjAw==",
        'RED'         => "AAAAAgAAAJcAAAAlAw==",
        'GREEN'       => "AAAAAgAAAJcAAAAmAw==",
        'YELLOW'      => "AAAAAgAAAJcAAAAnAw==",
        'BLUE'        => "AAAAAgAAAJcAAAAkAw==",
        'HOME'        => "AAAAAQAAAAEAAABgAw==",
        'VOLUP'       => "AAAAAQAAAAEAAAASAw==",
        'VOLUMEUP'    => "AAAAAQAAAAEAAAASAw==",
        'VOLDOWN'     => "AAAAAQAAAAEAAAATAw==",
        'VOLUMEDOWN'  => "AAAAAQAAAAEAAAATAw==",
        'MUTE'        => "AAAAAQAAAAEAAAAUAw==",
        'OPTIONS'     => "AAAAAgAAAJcAAAA2Aw==",
        'DOT'         => "AAAAAgAAAJcAAAAdAw==",
        '0'           => "AAAAAQAAAAEAAAAJAw==",
        '1'           => "AAAAAQAAAAEAAAAAAw==",
        '2'           => "AAAAAQAAAAEAAAABAw==",
        '3'           => "AAAAAQAAAAEAAAACAw==",
        '4'           => "AAAAAQAAAAEAAAADAw==",
        '5'           => "AAAAAQAAAAEAAAAEAw==",
        '6'           => "AAAAAQAAAAEAAAAFAw==",
        '7'           => "AAAAAQAAAAEAAAAGAw==",
        '8'           => "AAAAAQAAAAEAAAAHAw==",
        '9'           => "AAAAAQAAAAEAAAAIAw==",
        'GUIDE'       => "AAAAAQAAAAEAAAAOAw==",
        'INFO'        => "AAAAAQAAAAEAAAA6Aw==",
        'UP'          => "AAAAAQAAAAEAAAB0Aw==",
        'DOWN'        => "AAAAAQAAAAEAAAB1Aw==",
        'LEFT'        => "AAAAAQAAAAEAAAA0Aw==",
        'RIGHT'       => "AAAAAQAAAAEAAAAzAw==",
        'OK'          => "AAAAAQAAAAEAAABlAw==",
        'RETURN'      => "AAAAAgAAAJcAAAAjAw==",
        'NEXT'        => "AAAAAgAAAJcAAAA9Aw==",
        'PREVIOUS'    => "AAAAAgAAAJcAAAA8Aw==",
        'TV'          => "AAAAAgAAABoAAABXAw==",
        'TVPAUSE'     => "AAAAAgAAABoAAABnAw==",
        'MODE3D'      => "AAAAAgAAAHcAAABNAw==",
        'TEXT'        => "AAAAAQAAAAEAAAA/Aw==",
        'SUBTITLE'    => "AAAAAgAAAJcAAAAoAw==",
        'CHANUP'      => "AAAAAQAAAAEAAAAQAw==",
        'CHANNELUP'   => "AAAAAQAAAAEAAAAQAw==",
        'CHANDOWN'    => "AAAAAQAAAAEAAAARAw==",
        'CHANNELDOWN' => "AAAAAQAAAAEAAAARAw==",
        'SOURCE'      => "AAAAAQAAAAEAAAAlAw==",
        'PLAY'        => "AAAAAgAAAJcAAAAaAw==",
        'PAUSE'       => "AAAAAgAAAJcAAAAZAw==",
        'FORWARD'     => "AAAAAgAAAJcAAAAcAw==",
        'STOP'        => "AAAAAgAAAJcAAAAYAw==",
        'REWIND'      => "AAAAAgAAAJcAAAAbAw==",
        'RECORD'      => "AAAAAgAAAJcAAAAgAw==",
        'ASPECT'      => "AAAAAQAAAAEAAAA6Aw==",
        'HELP'        => "AAAAAgAAABoAAAB7Aw==",
        'DIGITAL'     => "AAAAAgAAABoAAAA7Aw==",
        'TRACKID'     => "AAAAAgAAABoAAAB+Aw==",
        'AUDIO'       => "AAAAAQAAAAEAAAAXAw==",
        'SEN'         => "AAAAAgAAABoAAAB9Aw==",
        'SYNCMENU'    => "AAAAAgAAABoAAABYAw==",
        'SCENESELECT' => "AAAAAgAAABoAAAB4Aw==",
    };

    if ( defined( $commands->{$command} ) ) {
        return $commands->{$command};
    }
    elsif ( $command eq "GetRemotecontrolCommands" ) {
        return $commands;
    }
    else {
        return "";
    }
}

sub BRAVIA_GetModelYear($) {
    my ($command) = @_;
    my $commands = {
        '1.0'       => "2011",
        '1.1'       => "2012",
        '1.0.4'     => "2013",
        '2.4.0'     => "2014",
    };

    if (defined( $commands->{$command})) {
        return $commands->{$command};
    } else {
        return "";
    }
}

sub BRAVIA_GetIrccRequest($) {
    my ($cmd) = @_;
    my $data = "<?xml version=\"1.0\"?>";
    $data .= "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">";
    $data .= "<s:Body>";
    $data .= "<u:X_SendIRCC xmlns:u=\"urn:schemas-sony-com:service:IRCC:1\">";
    $data .= "<IRCCCode>" . $cmd . "</IRCCCode>";
    $data .= "</u:X_SendIRCC>";
    $data .= "</s:Body>";
    $data .= "</s:Envelope>";
    
    return $data;
}

sub BRAVIA_GetUpnpRequest($$) {
    my ($cmd,$value) = @_;
    my $data = "<?xml version=\"1.0\"?>";
    $data .= "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">";
    $data .= "<s:Body>";
    if ($cmd eq "getVolume") {
      $data .= "<u:GetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">";
      $data .= "<InstanceID>0</InstanceID>";
      $data .= "<Channel>Master</Channel>";
      $data .= "</u:GetVolume>";
    } elsif ($cmd eq "setVolume") {
      $data .= "<u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">";
      $data .= "<InstanceID>0</InstanceID>";
      $data .= "<Channel>Master</Channel>";
      $data .= "<DesiredVolume>";
      $data .= $value;
      $data .= "</DesiredVolume>";
      $data .= "</u:SetVolume>";
    } elsif ($cmd eq "getMute") {
      $data .= "<u:GetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">";
      $data .= "<InstanceID>0</InstanceID>";
      $data .= "<Channel>Master</Channel>";
      $data .= "</u:GetMute>";
    } elsif ($cmd eq "setMute") {
      $data .= "<u:SetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">";
      $data .= "<InstanceID>0</InstanceID>";
      $data .= "<Channel>Master</Channel>";
      $data .= "<DesiredMute>";
      $data .= $value;
      $data .= "</DesiredMute>";
      $data .= "</u:SetMute>";
    }
    $data .= "</s:Body>";
    $data .= "</s:Envelope>";
    
    return $data;
}

sub BRAVIA_CheckRegistration($) {
  my ( $hash ) = @_;
  my $name = $hash->{NAME};

  my %mon2num = qw(
      jan 1  feb 2  mar 3  apr 4  may 5  jun 6
      jul 7  aug 8  sep 9  oct 10 nov 11 dec 12
  );

  if (defined $hash->{READINGS}{authExpires}{VAL}) {
    if($hash->{READINGS}{authExpires}{VAL} =~ m/^(\d{2})-(\w{3})-(\d{4}) ([0-2]\d):([0-5]\d):([0-5]\d)$/) {
        my $datetime = timelocal($6, $5, $4, $1, $mon2num{lc $2} - 1, $3 - 1900);
        if ($datetime < time()) {
          Log3 $name, 3, "BRAVIA $name: renew registration";
          BRAVIA_SendCommand( $hash, "register", "renew" );
        }
    }
  }  
}

1;
=pod
=begin html

<a name="BRAVIA"></a>
<h3>BRAVIA</h3>

=end html
=begin html_DE

<a name="BRAVIA"></a>
<h3>BRAVIA</h3>
<ul>
  Diese Module dient zur Steuerung von Sony TVs der BRAVIA-Serien beginnend mit dem Modelljahr 2011. 
  <br><br>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; BRAVIA &lt;ip-or-hostname&gt; [&lt;poll-interval&gt;]</code>
    <br><br>
    Bei der Definition eines BRAVIA Gerätes wird ein interner Task eingeplant,
    der regelmäßig den Status des TV prüft und weitere Informationen abruft.<br>
    Das Intervall des Tasks kann durch den optionalen Parameter &lt;poll-intervall&gt; in Sekunden gesetzt werden.
    Ansonsten wird der Task mit 45 Sekunden als Intervall definiert.
    <br><br>
    Nach der Definition eines Gerätes muss dieses einmalig im TV als Fernbedienung
    registriert werden (<a href=#BRAVIAregister><code>set register</code></a>).
    <br><br>
    Soweit die Readings nicht den allgemeinen AV Readings entsprechen, sind sie gruppiert:
    <table>
      <tr><td>s_*</td><td>: Status</td></tr>
      <tr><td>ci_*</td><td>: Inhaltsinfo</td></tr>
    </table>
    <br><br>
    Das Modul enthält vorgefertigte Layouts für <a href=#remotecontrol>remotecontrol</a> mit PNG und SVG.
    <br><br>
  </ul>
  <a name="BRAVIAset"></a>
  <b>Set</b> 
    <ul><b>channel</b>
      <ul>Liste alle bekannten Kanäle. Das Modul merkt sich alle aufgerufenen Kanäle.</ul>
    </ul>
    <ul><b>channelDown</b>
      <ul></ul>
    </ul>
    <ul><b>channelUp</b>
      <ul></ul>
    </ul>
    <ul><b>mute</b>
      <ul>Direkte Stummschaltung erfolgt nur per aktiviertem <a href=#BRAVIAupnp>Upnp</a>.</ul>
    </ul>
    <ul><b>off</b>
      <ul></ul>
    </ul>
    <ul><a name="BRAVIAon"></a><b>on</b>
      <ul>Einschalten des TV per WOL, wenn das Attribute <a href=BRAVIAmacaddr>macaddr</a> gesetzt ist.</ul>
    </ul>
    <ul><b>pause</b>
      <ul></ul>
    </ul>
    <ul><b>play</b>
      <ul></ul>
    </ul>
    <ul><b>record</b>
      <ul></ul>
    </ul>
    <ul><a name="BRAVIAregister"></a><b>register</b>
      <ul>Einmalige Registrierung von FHEM als Fernbedienung im TV.</ul>
      <ul>Bei <a href=#BRAVIArequestFormat>requestFormat</a> = "xml" erfolgt die Registrierung ohne Parameter.</ul>
      <ul>Bei <a href=#BRAVIArequestFormat>requestFormat</a> = "json" ist die Registrierung zweistufig.
          Beim Aufruf des Setter gibt es ein Eingabefeld:<br>
          Aufruf mit leerem Eingabefeld. Auf dem TV sollte eine PIN zur Registrierung erscheinen.<br>
          PIN im Eingabefeld eintragen und Registrierung noch mal ausführen</ul>
    </ul>
    <ul><a name="BRAVIArequestFormat"></a><b>requestFormat</b>
      <ul>"xml" für xml-basierte Kommunikation 2011er/2012er Geräte</ul>
      <ul>"json" für die Kommunikation seit der 2013er Generation</ul>
    </ul>
    <ul><b>remoteControl</b>
      <ul>Direktes Senden von Kommandos an den TV.</ul>
    </ul>
    <ul><b>statusRequest</b>
      <ul></ul>
    </ul>
    <ul><b>stop</b>
      <ul></ul>
    </ul>
    <ul><b>toggle</b>
      <ul>Wechselt den Einschaltstatus des TV.</ul>
    </ul>
    <ul><b>tvpause</b>
      <ul>Aktiviert Timeshift.</ul>
    </ul>
    <ul><a name="BRAVIAupnp"></a><b>upnp</b>
      <ul>Aktiviert Upnp zum Abfragen und Stellen der Lautstärke.</ul>
    </ul>
    <ul><b>volume</b>
      <ul>Direktes Setzen der Lautstärke erfolgt nur per aktiviertem <a href=#BRAVIAupnp>Upnp</a>.</ul>
    </ul>
    <ul><b>volumeDown</b>
      <ul></ul>
    </ul>
    <ul><b>volumeUp</b>
      <ul></ul>
    </ul>
    <br><br>
  <a name="BRAVIAattr"></a>
  <b>Attributes</b> 
  <ul><b>macaddr</b>
    <ul>Ermöglicht das Einschalten des TV per WOL.</ul>
  </ul>
</ul>

=end html_DE
=cut
