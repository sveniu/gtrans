#!/usr/bin/env perl -w
# vim: set sw=2 ts=2 sta et:

# GTrans: Automatic translation in Irssi using the Google Language API
# by Sven Ulland <svensven@gmail.com>

#TODO:
# what determines the value of isreliable? the api doc doesn't say.
# fix utf-8 handling.
#   + use this:   utf8::decode($text); Some problems with html entities?
#   + note in the doc that only utf-8 is supported
# DONE: error handling. How to print with activity?
# DONE: colorized? formatting string? how do other scripts do that?
#       (no use of mirc colors)
# DONE: outbound translation: configurable so that you can choose:
#   + DONE: a default outbound language without any writing overhead
#   + DONE: choose language in text:   en:jeg liker fisk  (prone to error)
#   + DONE: a command:   /gtrans en:jeg liker fisk
# outbound translation status (confidence) should be shown on the following line
# DONE: translate notices, privmsgs, etc?
# translate topic
#   + translate incoming topic
#   + translate outgoing topic
#   + keep translated topic in topic bar with toggle
# debugging option
#   + DONE: general debugging
#   + consistent debugging levels. needs testing
# BIG FAT PRIVACY WARNING: Text is sent through google!
# DONE: decide to use " or '. Primarily "
# DONE: option to show original text
# DONE: code reuse (at least partially)
# handle max len (500 *bytes*). Is actually handled by the WGL API
# DONE: whitelist function, to specify which sources should be translated:
#   + DONE: whitelist channels and nicks
#   + WONTFIX: ^ how about servers/connections? same chan on many servers.
#   + DONE: whitelist all by specifying '*'
# DONE: handle signal 'message private' vs 'message public'?
# DONE: my languages, a list of languages that should not be modified.
# documentation
# DONE: check how to interact with logging
# doc: note that spelling is important
# DONE: signal_add vs signal_add_{first,last} ?
# link to http://code.google.com/apis/ajaxlanguage/documentation/reference.html#LangNameArray
# doc: note about fetching and using the WGL module with irssi.
# what are the sbitems, commands and modules for in %IRSSI?
# DONE: enable for /me too
# doc: note lack of conn/srv differentiation
# DONE: test command to translate without sending anything over the wire.
# better code reuse. Lots of duplication now.
# DONE: /gtrans fo:bar is overridden by event_output_msg :(
# DONE: toggle showing original text or overwriting it. watch out for logging!
#   + logging is done at the end of the chain :/

use strict;

use vars qw($VERSION %IRSSI);
use Irssi;
$VERSION = "0.0.0";
%IRSSI = (
    authors     => "Sven Ulland",
    contact     => "svensven\@gmail.com",
    name        => "GTrans",
    description => "Automatic translation via the Google Language API",
    license     => "GPLv2",
    url         => "http://scripts.irssi.org/",
    changed     => $VERSION,
    modules     => "WebService::Google::Language",
    commands    => "gtrans"
);

use Data::Dumper qw(Dumper);
use WebService::Google::Language;

my $service = WebService::Google::Language->new(
  "referer" => "http://scripts.irssi.org/",
  "agent"   => "$IRSSI{name} $VERSION for Irssi",
  "timeout" => 5,
  "src"     => "",
  "dest"    => "",
);

# Urgh. $glob_cmdpass is set to 1 when using gtrans_cmd() and later checked in
# event_output_msg(). The reason is that event_output_msg() is called
# twice: first by cmd_gtrans(), then by the event "send text".
my $glob_cmdpass = 0;

sub dbg {
  my ($level, $msg) = @_;
  return unless ($level <= Irssi::settings_get_int("gtrans_debug"));

  my %dbgcol = (
    1 => "%G",
    2 => "%Y",
    3 => "%C",
    4 => "%M",
    5 => "%R",
  );

  print CLIENTCRAP "%W$IRSSI{name} " .
                   "%Bdebug%W($dbgcol{$level}$level%W)>%n $msg";
}

sub err {
  my $msg = shift;
  print CLIENTCRAP "%W$IRSSI{name} %Rerror%W>%n $msg";
}

sub inf {
  my $msg = shift;
  print CLIENTCRAP "%W$IRSSI{name} %Ginfo%W>%n $msg";
}

sub usage {
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n " .
                   "/$IRSSI{commands} [-t|--test] <lang>:<message>";
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n " .
                   "Example: /$IRSSI{commands} fr:this message " .
                   "will be translated to french and sent to the " .
                   "currently active window.";
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n " .
                   "Example: /$IRSSI{commands} -t fi:this message " .
                   "will be translated to finnish, but *won't* be " .
                   "sent out. use this to test translations.";
}

sub dehtml {
  # FIXME: The only HTML entity seen so far is &#39;
  $_[0] =~ s/&#39;/'/g;
}

sub wgl_process {
  my %args = @_;
  dbg(5, "wgl_process(): input %args: " . Dumper(\%args));

  my $result = $args{func}(%args);
  dbg(4, "wgl_process() wgl_func() output: " . Dumper(\$result));

  my $ok = 1;
  if ($result->error) {
    err(sprintf "wgl_process() wgl_func() code %s: %s",
        $result->code,
        $result->message);
    $ok = 0;
  }

  return $result;
}

sub event_input_msg {
  my $subname = "event_input_msg";
  my ($server, $msg, $nick, $address, $target) = @_;

  return unless Irssi::settings_get_bool("gtrans_input_auto");

  my $sig = Irssi::signal_get_emitted();
  my $witem;

  dbg(5, "$subname() args: " . Dumper(\@_));

  my $do_translation = 0;

  if ($sig eq "message private") {
    # Private message.
    $witem = Irssi::window_item_find($nick);

    # Check whether the source $nick is in the whitelist.
    dbg(3, "$subname() Looking for nick \"$nick\" in whitelist");
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist"))) {
      $do_translation = 1 if ($nick eq $_ or $_ eq "*");
    }
  } else { # $sig eq "message public"
    # Public message.
    $witem = Irssi::window_item_find($target);

    # Check whether the $target is in the whitelist.
    dbg(3, "$subname() Looking for channel \"$target\" " .
           "in whitelist");
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist"))) {
      $do_translation = 1 if ($target eq $_ or $_ eq "*");
    }
  }

  unless ($do_translation) {
    dbg(1, sprintf "Channel (\"$target\") or nick (\"$nick\") is " .
                   "not whitelisted");
    return;
  }

  dbg(2, sprintf "$subname() Channel (\"$target\") or nick " .
                 "(\"$nick\") is whitelisted");

  # Prepare arguments for language detection.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->detect(@_) },
    "text" => $msg,
  );

  # Run language detection.
  my $result = wgl_process(%args);

  dbg(4, "$subname() wgl_process() detect returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "$subname(): Language detection failed");
    err(sprintf "Language detection failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # Don't translate my languages.
  foreach (split(/ /, Irssi::settings_get_str("gtrans_my_lang"))) {
    $do_translation = 0 if($result->language eq $_);
  }

  unless ($do_translation) {
    dbg(2, "$subname() Incoming language " .
           "\"$result->language\" matches my lang(s). " .
           "Not translating.");
    return;
  }

  dbg(1, sprintf "Detected language \"%s\", confidence %.3f",
                 $result->language, $result->confidence);

  my $confidence = $result->confidence;
  my $reliable = $result->is_reliable;

  # Prepare arguments for translation.
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
    "dest" => (split(/ /,
        Irssi::settings_get_str("gtrans_my_lang")))[0]
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "$subname() wgl_process() translate returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  if (Irssi::settings_get_bool("gtrans_show_orig")) {
    my $trmsg = sprintf "[%%B%s%%n:%s%.2f%%n] %s",
        $result->language,
        $reliable ? "%g" : "%r",
        $confidence,
        $result->translation;
    utf8::decode($trmsg);
    dehtml($trmsg);

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
    $witem->print($trmsg, MSGLEVEL_CLIENTCRAP);
  }
  else {
    $msg = sprintf "[%s:%.2f] %s",
        $result->language,
        $confidence,
        $result->translation;
    utf8::decode($msg);
    dehtml($msg);

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
  }

  dbg(1, "Incoming translation successful");
}

sub event_output_msg {
  my $subname = "event_output_msg";
  my ($msg, $server, $witem, $force_lang) = @_;

  dbg(5, "$subname() args: " . Dumper(\@_));

  # Safeguard to stop double translations when using /gtrans.
  if ($glob_cmdpass) {
    $glob_cmdpass = 0;
    Irssi::signal_continue($msg, $server, $witem);
    return;
  }

  return unless (
      (Irssi::settings_get_int("gtrans_output_auto") > 0 and
       Irssi::settings_get_int("gtrans_output_auto") <= 2)
         or $force_lang);

  # Determine destination language before doing translation.
  my $dest_lang;
  if($force_lang) {
    $dest_lang = $force_lang;
  }
  elsif (Irssi::settings_get_int("gtrans_output_auto") eq 1) {
    # Semiauto translation. Here we preprocess the msg to determine
    # destination language. The WGL API cannot fetch the list of valid
    # languages, so we simply try to see if the language is valid.
    if ( $msg =~ /^([a-z]{2}(-[a-z]{2})?):(.*)/i) {
      dbg(2, "$subname() dest_lang \"$1\", msg \"$3\"");
      $dest_lang = $1;
      $msg = $3;
    }
  }
  elsif (Irssi::settings_get_int("gtrans_output_auto") eq 2) {
    # Fully automated translation.
    # To avoid accidents, verify that $witem->{name} is whitelisted.
    dbg(3, "$subname() Looking for target \"" .
           $witem->{name} . "\" in whitelist");

    my $do_translation = 0;
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist"))) {
      $do_translation = 1 if ($witem->{name} eq $_);
      $do_translation = 1 if ($_ eq "*");
    }

    unless ($do_translation) {
      dbg(1, sprintf "Target \"" . $witem->{name} . "\" is " .
                     "not whitelisted");
      return;
    }

    dbg(2, sprintf "$subname() Target \"" . $witem->{name} .
                   "\" is whitelisted");
    $dest_lang = Irssi::settings_get_str("gtrans_output_auto_lang");
  }

  unless ($dest_lang and $msg) {
    err("Empty destination language or message");
    return;
  }

  # Prepare arguments for translation.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
    "dest" => $dest_lang
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "$subname() wgl_process() output: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "$subname() Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  my $trmsg;
  if ($result->language ne $dest_lang) {
    $trmsg = $result->translation;
    utf8::decode($trmsg);
    dehtml($trmsg);
  }

  if($force_lang) {
    # Emit new signal, since we came from cmd_gtrans().
    $glob_cmdpass = 1;
    dbg(3, "$subname():" . __LINE__ .
           " Emitting \"send text\" signal");
    Irssi::signal_emit("send text", $trmsg, $server, $witem);
    return;
  }

  Irssi::signal_continue($trmsg, $server, $witem);

  if (Irssi::settings_get_bool("gtrans_show_orig")) {
    my $origmsg = sprintf "(orig:%%B%s%%n) %s",
        $result->language,
        $msg;
    $witem->print($origmsg, MSGLEVEL_CLIENTCRAP);
  }

  dbg(1, "Outbound auto-translation successful");
}

sub event_topic {
  # signal "message own_public" parameters:
  # my ($server, $channel, $topic, $nick, $target) = @_;

  return unless Irssi::settings_get_bool("gtrans_topic_auto");

  dbg(5, "event_topic() args: " . Dumper(\@_));

  my ($server, $channel, $msg, $nick, $target) = @_;

  my $do_translation = 0;

  # Check whether $channel is in the whitelist.
  dbg(3, "event_topic() Looking for channel \"$channel\" in " .
         "whitelist");
  foreach (split(/ /,
      Irssi::settings_get_str("gtrans_whitelist"))) {
    $do_translation = 1 if ($channel eq $_);
    $do_translation = 1 if ($_ eq "*");
  }

  unless ($do_translation) {
    dbg(1, sprintf "Channel $channel is not whitelisted. " .
                   "Not translating topic");
    return;
  }

  dbg(2, sprintf "event_topic() Channel $channel is whitelisted");

  # Prepare arguments for language detection.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->detect(@_) },
    "text" => $msg,
  );

  # Run language detection.
  my $result = wgl_process(%args);

  dbg(4, "event_topic() wgl_process() detect returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "event_topic(): Language detection failed");
    err(sprintf "Language detection failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # Don't translate my languages.
  foreach (split(/ /, Irssi::settings_get_str("gtrans_my_lang"))) {
    $do_translation = 0 if($result->language eq $_);
  }

  unless ($do_translation) {
    dbg(2, "event_topic() Incoming language " .
           "\"$result->language\" matches my lang(s). " .
           "Not translating.");
    return;
  }

  dbg(1, sprintf "Detected language \"%s\", confidence %.3f",
                 $result->language, $result->confidence);

  my $confidence = $result->confidence;

  # Prepare arguments for translation.
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
    "dest" => (split(/ /,
        Irssi::settings_get_str("gtrans_my_lang")))[0]
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "event_topic() wgl_process() translate returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "Topic translation failed");
    err(sprintf "Topic translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # FIXME: Don't alter messages!
  $msg = sprintf "[%s:%.2f] %s",
      $result->language, $confidence, $result->translation;

  utf8::decode($msg);
  dehtml($msg);

  # FIXME: More info about result?
  dbg(1, "Incoming topic translation successful");

  Irssi::signal_continue($server, $channel, $msg, $nick, $target);
}

sub cmd_gtrans {
  my $subname = "cmd_gtrans";
  my ($msg, $server, $witem) = @_;

  dbg(5, "$subname() input: " . Dumper(\@_));

  if ($msg =~ /^(|help|-h|--help|-t|--test)$/) {
    usage();
    return;
  }

  my $testing_mode = 0;
  if ($msg =~ /^(-t|--test) /) {
    $testing_mode = 1;
    $msg =~ s/^(-t|--test) //;
  }

  return unless ($testing_mode or
                    ($witem and
                        ($witem->{type} eq "CHANNEL" or
                         $witem->{type} eq "QUERY")));

  # Determine destination language before doing translation.
  my $dest_lang;

  # FIXME: What about languages on the form "xx-yy"?
  if ( $msg =~ /^([a-z]{2}):(.*)/i) {
    dbg(2, "$subname() dest_lang \"$1\", msg \"$2\"");
    $dest_lang = $1;
    $msg = $2;
  } else {
    dbg(2, "$subname() syntax error");
  }

  unless ($dest_lang and $msg) {
    err("Empty destination language or msg");
    usage();
    return;
  }

  if ($testing_mode) {
    # Prepare arguments for translation.
    utf8::decode($msg);
    my %args = (
      "func" => sub { $service->translate(@_) },
      "text" => $msg,
      "dest" => $dest_lang
    );

    # Run translation.
    my $result = wgl_process(%args);

    dbg(4, "$subname() wgl_process() output: " . Dumper(\$result));

    if ($result->error) {
      dbg(1, "$subname(): Translation failed");
      err(sprintf "Translation failed with code %s: %s",
          $result->code, $result->message);
      return;
    }

    $msg = $result->translation;
    utf8::decode($msg);
    dehtml($msg);

    dbg(1, "Outbound translation successful");

    $witem = Irssi::active_win();
    $witem->print(sprintf
        ("%%GGTrans test (%%B%s%%n->%%B%s%%G):%%n %s",
        $result->language,
        $dest_lang,
        $msg), MSGLEVEL_CLIENTCRAP);
  }
  else {
    event_output_msg($msg, $server, $witem, $dest_lang);
  }
}

print CLIENTCRAP "%W$IRSSI{name} loaded. " .
                 "Hints: %n/$IRSSI{commands} help";

# Register gtrans settings.
Irssi::settings_add_bool("gtrans", "gtrans_input_auto",          1);
Irssi::settings_add_bool("gtrans", "gtrans_topic_auto",          0);
Irssi::settings_add_bool("gtrans", "gtrans_show_orig",           1);
Irssi::settings_add_int ("gtrans", "gtrans_output_auto",         0);
Irssi::settings_add_str ("gtrans", "gtrans_output_auto_lang", "fr");
Irssi::settings_add_str ("gtrans", "gtrans_my_lang",          "en");
Irssi::settings_add_int ("gtrans", "gtrans_debug",               0);
Irssi::settings_add_str ("gtrans", "gtrans_whitelist",          "");

# Register /gtrans command.
Irssi::command_bind("gtrans",                    "cmd_gtrans");

# Register events for incoming messages/actions.
Irssi::signal_add_last("message public",         "event_input_msg");
Irssi::signal_add_last("message private",        "event_input_msg");
#TODO: Irssi::signal_add("message irc action",          "event_input_msg");
#TODO: Irssi::signal_add("message irc notice",          "event_input_msg");

# Register events for outgoing messages/actions.
#Irssi::signal_add("message own_public",     "event_output_msg");
#Irssi::signal_add("message own_private",    "event_output_msg");
#Irssi::signal_add("message irc own_action", "event_output_msg");
#Irssi::signal_add("message irc own_notice", "event_output_msg");
Irssi::signal_add("send text", "event_output_msg");

# Register events that need special handling.
####Irssi::signal_add("event topic",          "event_topic");
