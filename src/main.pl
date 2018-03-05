#!/usr/bin/perl
#
# Copyright 2008-2010, 2018 University Of Helsinki (The National Library Of Finland)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

my %config = ();
my $daemon = 0;
my %children = ();
my $is_child = 0;
my $pid_file = undef;

use POSIX qw(setsid :sys_wait_h);

sub KILL_handler
{
  my ($signal) = @_;
  writelog("SIG$signal received" . ($is_child ? ' (child)' : ' (main)'));
            
  if (!$is_child)
  {
    debuglog('Sending TERM signal to children (' . scalar(keys %children) . ')');
    foreach my $child (keys %children)
    {
      if ($children{$child})
      {
        debuglog("Signaling child $child");
        kill(TERM, $child);
      }
    }
  }
        
  unlink($pid_file) if ($daemon);
  exit(0);
}

sub CHILD_handler
{
  my $counter = 0;
  # waitpid should return > 0 if there are children, but this does not
  # always seem to be the case, so we check for -1 and use a counter as
  # a safeguard.
  while ((my $pid = waitpid(-1, WNOHANG)) != -1 && $counter++ < 100)
  {
    if (WIFEXITED($?))
    {
      debuglog("Child $pid exited");
      # Setting an existing value ought to be relatively safe
      $children{$pid} = 0;
    }
  }
  $SIG{CHLD} = \&CHILD_handler; # in case of unreliable signals
  return 1;
}


$SIG{KILL} = \&KILL_handler;
$SIG{INT} = \&KILL_handler;
$SIG{HUP} = \&KILL_handler;
$SIG{TERM} = \&KILL_handler;
$SIG{CHLD} = \&CHILD_handler;

use strict;
use Getopt::Long;
use IO::Socket;
use Net::hostent;
use CGI qw(:standard);
use POSIX qw(setsid);
use Cwd qw(abs_path);
use File::Basename qw(dirname);

my $cmd_path = dirname(abs_path($0));

my %texts = ();

# MAIN
{
  my $config_file = '';
  my $work_dir = undef;

  GetOptions(
    "config=s" => \$config_file,
    "pidfile=s" => \$pid_file,
    "workdir=s" => \$work_dir,
    "daemon!" => \$daemon,
  );

  if (scalar(@ARGV) || !$config_file)
  {
    print qq|Usage: opac_enhancer.pl --config=<filename> --workdir=<directory> [--pidfile=<filename> --daemon]

  config    Name of the configuration file (full path)
  pidfile   File where process id of the daemon is stored
  workdir   Working directory for the daemon
  daemon    Requests the script to start as a daemon (detached from console)

|;
    exit(1);
  }

  read_config($config_file);

  if ($work_dir)
  {
    chdir($work_dir) || die("Could not chdir to $work_dir: $!");
  }

  writelog("OPAC Enhancer startup");

  if ($daemon)
  {
    die('PID file not specified') if (!$pid_file);
    umask(0);
    die("PID file $pid_file already exists") if (-e $pid_file);
    open(STDIN, '</dev/null') || die("Could not redirect STDIN to /dev/null: $!");
    open(STDOUT, ">/dev/null") || die("Could not redirect STDOUT to /dev/null: $!");
    open(STDERR, ">/dev/null") || die("Could not redirect STDERR to /dev/null: $!");
    open(STDERR, ">$config{'general'}{'log file'}.err") || die("Could not redirect STDERR to $config{'general'}{'log file'}.err: $!");
    defined(my $pid = fork()) || die("Can't fork: $!");
    if($pid)
    {
      my $fh;
      open($fh, ">$pid_file") || die("Could not open pid file $pid_file: $!");
      print $fh "$pid\n";
      close($fh);
      exit(0);
    }
    setsid() || die("Can't start a new session: $!");
  }

  $| = 1;


  my $server = IO::Socket::INET->new(Proto => 'tcp',
    LocalAddr => $config{'general'}{'listening address'},
    LocalPort => $config{'general'}{'listening port'},
    Listen => SOMAXCONN, Reuse => 1) || die("Could not create listening socket: $@");

  writelog("Listener started on port $config{'general'}{'listening port'}");

  debuglog("Debug logging enabled");

  while (1)
  {
    my $apache = $server->accept();
    next if (!$apache);

    if (my $pid = fork())
    {
      $children{$pid} = 1;
      debuglog("New connection for child $pid");
    }
    elsif (!defined($pid))
    {
      error("Cannot fork child: $!\n");
      next;
    }
    else
    {
      $is_child = 1;
      my $www_server = IO::Socket::INET->new(Proto => "tcp",
        PeerAddr => $config{'aleph'}{'www server address'},
        PeerPort => $config{'aleph'}{'www server port'},
        Reuse => 1);
      if (!$www_server)
      {
        error("Could not connect to www server: $!");
        my $status = $config{'general'}{'connection error status'} || 'Service Temporarily Unavailable';
        my $message = $config{'general'}{'connection error message'} || 'The service is currently unavailable due to maintenance downtime. Please try again later.';
        my $cgi = new CGI();
        my $response = "HTTP/1.1 503 Service Temporarily Unavailable\n";
        $response .= $cgi->header(-type => 'text/html',
          -status => $status,
          -expires => '-1d');
        $response .= $cgi->start_html(-title => $status) .
          $cgi->h1($status) .
          $cgi->p($message) .
          $cgi->end_html();
        syswrite($apache, $response, length($response));
        exit(1);
      }

      $apache->autoflush(1);
      $www_server->autoflush(1);

      # Loop really only once, as the while is only for easy exit.
      while (1)
      {
        # Read from the Apache module
        my $data;
        my $data_part = '';
        my $data_len = 0;
        while ((my $read_len = sysread($apache, $data_part, 1024 * 1024)) > 0)
        {
          debuglog("Read $read_len from Apache") if ($config{'general'}{'debug'} >= 2);
          $data .= $data_part;
          $data_len += $read_len;
          last if ($data_len >= 4 && $data_len >= get_length($data, 0));
        }
        dump_data("\n\n$$ Request: $data\n\n") if ($config{'general'}{'debug'} >= 2);

        my %request_attrs = ();
        # We will get the following attributes in the hash:
        # client_ip, user_agent, path, cookies, query, server_name, headers
        parse_request($data, \%request_attrs);

        if ($config{'general'}{'debug'})
        {
          foreach my $key (keys %request_attrs)
          {
            debuglog("Request param $key = $request_attrs{$key}");
          }
        }

        # Apply request modules
        last if (processRequest(\$apache, \$www_server, \%request_attrs, \$data, $data_len));

        # Send the request to www_server
        syswrite($www_server, $data, $data_len);

        # Read response
        $data = '';
        $data_part = '';
        $data_len = 0;
        while ((my $read_len = sysread($www_server, $data_part, 1024 * 1024)) > 0)
        {
          debuglog("Read $read_len from WWW Server") if ($config{'general'}{'debug'} >= 2);
          $data .= $data_part;
          $data_len += $read_len;
          last if ($data_len >= 4 && $data_len >= get_length($data, 0));
        }
        dump_data("\n\n$$ Original response: $data\n\n") if ($config{'general'}{'debug'} >= 2);
        my $content_pos = index($data, "\r\n\r\n");
        if ($content_pos >= 0)
        {
          $content_pos += 4;
        }
        else
        {
          $content_pos = index($data, "\n\n");
          if ($content_pos >= 0)
          {
            $content_pos += 2;
          }
          else
          {
            error("Could not parse response content and headers. Data dump:\n$data");
            syswrite($apache, $data, $data_len);
            last;
          }
        }
        my $headers = substr($data, 0, $content_pos);

        # Aleph (at least 18.01) sends only LF, which violates RFC 2616 that specifies
        # that the end of line marker in headers is CR LF. Fix the headers.
        my $old_headers = $headers;
        $headers =~ s/\n/\r\n/gs if (index($headers, "\r") < 0);
        $data_len += length($headers) - length($old_headers);

        my $content = substr($data, $content_pos);
        processResponse(\$apache, \$www_server, \%request_attrs, \$headers, \$content, $data_len);
        my $len = length($content);
        $headers =~ s/Content-Length: (\d*)/Content-Length: $len/;
        dump_data("\n\n $$ Modified response: $headers -- $content\n\n") if ($config{'general'}{'debug'} >= 2);
        syswrite($apache, $headers . $content, length($headers . $content));

        last;
      }
      debuglog("Child $$ done");

      exit(0);
    }
  }
}

sub read_config($)
{
  my ($config_file) = @_;
  my $section = '';
  my @mandatory = (
    'general-log file',
    'general-listening address',
    'general-listening port',
    #'general-connection error status',
    #'general-connection error message',
    'aleph-www server address',
    'aleph-www server port',
    #'translation-global',
    #'translation-eng',
    #'translation-fin',
  );

  my $fh;
  open($fh, "<$config_file") || die("Could not open configuration file $config_file for reading: $!");

  while (my $orig_line = <$fh>)
  {
    my $line = $orig_line;
    $line =~ s/\s*#.*$//g;
    $line =~ s/^\s*(.*)\s*$/$1/;
    $line =~ s/\s*=\s*/=/g;

    next if (!$line);

    if ($line =~ /^\[([^\s]+)\]/)
    {
      $section = $1;
      next;
    }

    if ($line =~ /([\w\s]+?)=(.*)/)
    {
      $config{$section}{lc($1)} = $2;
    }
    else
    {
      die("Invalid configuration file line: $orig_line");
    }
  }
  close($fh);

  # Verify that the configuration file has all the mandatory settings
  foreach my $section_setting (@mandatory)
  {
    my ($section, $setting) = $section_setting =~ /(.+?)-(.+)/;
    die ("Mandatory setting $section/$setting not defined") if (!$config{$section}{$setting});
  }
}

sub processRequest($$$$$)
{
  my ($apache_ref, $www_server_ref, $request_attrs_ref, $data_ref, $datalen) = @_;
  my $modified;

  foreach my $module (keys(%{$config{request}})) {
    my $cb = require($config{request}{$module});
    my $module_config = $config{"request_$module"} if $config{"request_$module"};

    debuglog('Executing request module $module');

    my $retval = &$cb($apache_ref, $www_server_ref, $request_attrs_ref, $data_ref, $datalen, $module_config);
    if (!$modified && $retval) {
      $modified = 1;
    }
  }

  return $modified;
}

sub processResponse($$$$$$)
{
  my ($apache_ref, $www_server_ref, $request_attrs_ref, $headers_ref, $content_ref, $datalen) = @_;

  foreach my $module (keys(%{$config{response}})) {
    my $cb = require($config{response}{$module});
    my $module_config = $config{"response_$module"} if $config{"response_$module"};

    debuglog('Executing response module $module');

    &$cb($apache_ref, $www_server_ref, $request_attrs_ref, $headers_ref, $content_ref, $datalen, $module_config);
  }
}

sub parse_request($$)
{
  my ($request, $attrs_ref) = @_;

  # The request is a length-prefix string that contains the following
  # length-prefix strings (the length includes a trailing \0):
  # client_ip, user_agent, path, cookies, query, server_name, headers

  my $all = substr($request, 4, get_length($request, 0) - 1);

  my @attrlist = ('client_ip', 'user_agent', 'path', 'cookies',
    'query', 'server_name', 'headers');

  my $pos = 0;
  foreach my $attr (@attrlist)
  {
    my $len = get_length($all, $pos);
    $attrs_ref->{$attr} = substr($all, $pos + 4, $len - 1);
    $pos += $len + 4;
  }
}

sub get_length($$)
{
  my ($string, $pos) = @_;

  return unpack('L', substr($string, $pos, 4));
}

sub writelog($)
{
  my ($str) = @_;

  $str = "[INFO] $str" if (substr($str, 0, 1) ne '[');

  my ($sec, $min, $hour, $day, $mon, $year) = localtime(time());
  my $msg;
  $msg = sprintf("[%04d-%02d-%02d %02d:%02d:%02d] %d %s\n", $year + 1900, $mon + 1, $day, $hour, $min, $sec, $$, $str);

  my $fh;
  if (!open ($fh, ">>$config{'general'}{'log file'}"))
  {
    warn("Could not open log file for appending: $!");
  }
  else
  {
    print $fh $msg;
    close($fh);
  }

  print $msg if (!$daemon);
}

sub error($)
{
  my ($str) = @_;

  writelog("[ERROR] $str");
}

sub debuglog($)
{
  my ($str) = @_;

  return if (!$config{'general'}{'debug'});

  writelog("[DEBUG] $str");
}

sub dump_data($)
{
  my ($data) = @_;

  my $fh;
  if (!open($fh, ">>dump.dat"))
  {
    error("Could not open dump file dump.dat for writing: $!");
    return;
  }
  print $fh $data;
  close($fh);
}
