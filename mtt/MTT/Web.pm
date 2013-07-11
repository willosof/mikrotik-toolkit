package MTT::Web;

use strict;
use Data::Dumper;
use HTTP::Tiny;
use IO::Select;
use MIME::Base64;
use Template;
use MIME::Types qw(by_suffix by_mediatype import_mime_types);


our $buffer = {};
our $request = {};
our $response = {};
our $state = {};

our $tt = Template->new({
	INCLUDE_PATH => './tpl',
	EVAL_PERL    => 1,
	WRAPPER      => '_design.tt',
}) || die $Template::ERROR, "\n";

sub new {
	my $class = shift;

	my $select = IO::Select->new();

	my $socket = IO::Socket::INET->new(
		Listen    => 30,
		LocalAddr => '0.0.0.0',
		LocalPort => 8037,
		Proto     => 'tcp',
		Blocking  => 0,
		Reuse     => 1,
	) or die ("Couldnt listen on http://0.0.0.0:8037. Port busy?!");

	my $self = { 
		'select' => $select,
		'socket' => $socket
	};

	$self->{'select'}->add($self->{'socket'});

	main::log("www","Listening on http://0.0.0.0:8037");

	bless $self, $class;
	return $self;


}


sub tick {
	my ($self) = @_;

	while(my @ready = $self->{'select'}->can_read(0)) {

		foreach my $fin (@ready) {
			my $fh;

			if ($fin == $self->{'socket'}) {
				my $fhnew = $fin->accept;
				binmode($fhnew);#, ":encoding(UTF-8)");
				$self->{'select'}->add($fhnew);
				$state->{$fhnew} = 1;
				$fh = $fhnew;
			} 

			else {
				$fh = $fin;
			}

			if (!defined $buffer->{$fh}) { $buffer->{$fh} = ""; }

			my $input;
			my $rv = sysread $fh, $input, 64*1024;

			if ($rv) {

				$buffer->{$fh} .= $input;
				if (length $input) {
					while(defined($buffer->{$fh}) && length($buffer->{$fh}) && $buffer->{$fh} =~ /\n/) {
						while(length($buffer->{$fh}) && $buffer->{$fh} =~ s/^([^\r\n]*)\r?\n//gsi) {
							if (not defined $1) {
								$self->http_in($fh, "");
							} else {
								$self->http_in($fh, $1);
							}
						}
					}
				}
			} 

			else {
				$self->http_close($fh);				
			} 


		}
	}

	return 1;
}

sub http_close {
	my ($self, $fh) = @_;
	delete $buffer->{$fh};
	delete $request->{$fh};
	delete $response->{$fh};
	delete $state->{$fh};
	$self->{'select'}->remove($fh);
	$fh->close();
	return 1;
}

sub http_out {
	my ($self, $fh, $output) = @_;
	$fh->send($output);
}

sub http_in {

	my ($self, $fh, $input) = @_;

	if ($state->{$fh} == 1 && length($input)) {
		
		if ($input =~ /^GET (.+) HTTP\/(1.[01])$/) {	
			$request->{$fh}->{"REQUEST_URI"} = $1;
			main::log("www","GET ".$request->{$fh}->{"REQUEST_URI"});
			$request->{$fh}->{"REQUEST_VERSION"} = $2;
			$request->{$fh}->{'headers'} = [];
			$state->{$fh}++;
		} 

		else {
			$self->http_response($fh, "Invalid request method", 400); #bad request
		}
	}
	elsif ($state->{$fh} == 2 && length($input)) {
		if ($input =~ /^([^:]+): (.+)$/) {
			push @{$request->{$fh}->{'headers'}}, [$1, $2];
		} else {
			$self->http_response($fh, "Broken headers", 400); #bad request
		}
	}

	elsif ($state->{$fh} == 2) {
		$self->http_request($fh);
	}

	return 1;


}
sub http_request {	
	my ($self, $fh) = @_;

	my ($scheme, $authority, $path, $query, $fragment) 
		= $request->{$fh}->{'REQUEST_URI'} 
		=~ m|(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;

	$request->{$fh}->{'uri'} = {
		'scheme' => $scheme, 
		'authority' => $authority, 
		'path' => $path, 
		'query' => $query, 
		'fragment' => $fragment
	};

	$response->{$fh}->{'content'} = "No content?!";

	my $routed = 1;

	my $location = $request->{$fh}->{'uri'}->{'path'};
	
	$location =~ s/\.\.\///gsi;
	$location =~ s/\/\.\.//gsi;
	$location =~ s/\.\.//gsi;

	###############################################################

	if ($location eq "/") {
		main::log("www","Controller: /");
		push @{$response->{$fh}->{'headers'}}, ["Content-Type","text/html; charset=UTF-8"];
		$response->{$fh}->{'content'} = $self->http_template(
			"index.tt", {
				'data' => "test",
			}
		);
	}

	elsif ($location =~ /^\/static\/([-_a-zA-Z0-9.\/]+\.[a-zA-Z]+)$/) {
		main::log("www","Controller: /static/$1");
		my ($mime_type, $encoding) = by_suffix($location);
		push @{$response->{$fh}->{'headers'}}, ["Content-Type",$mime_type];
		my $fhf; 
		# TODO CHAOS CODE TODO CHAOS CODE TODO CHAOS CODE TODO CHAOS CODE TODO
		if (open $fhf, "<", "static/$1") {
			main::log("www","Controller: open( /static/$1 )");
			push @{$response->{$fh}->{'headers'}}, ["Content-Type",$mime_type];
			my $data = "";
			sysread $fhf, $data, 1024*64 or die("ugh: $@ $!");
			$response->{$fh}->{'content'} = substr($data,0);
		}
		else {
			main::log("www","Controller: !open( /static/$1 )");
			push @{$response->{$fh}->{'headers'}}, ["Content-Type","text/plain"];
			$response->{$fh}->{'content'} = "Sorry, no such static file.";
		}
	}

	elsif ($location eq "/syslog") {
		main::log("www","Controller: /syslog");
		$response->{$fh}->{'content'} = Dumper $main::log;
	}

	elsif ($location eq "/config") {
		main::log("www","Controller: /config");
		$response->{$fh}->{'content'} = Dumper $main::config;
	}

	elsif ($location eq "/backup") {
		main::log("www","Controller: /backup");
		$response->{$fh}->{'content'} = Dumper $main::backup;
	}

	else { 
		main::log("www","Controller: <none>");
		$response->{$fh}->{'content'} = "Not routed.";
		$routed = 0; 
	}

	###############################################################

	main::log("www","Controller (done)");
	if ($routed) {
		$self->http_response($fh, "OK", 200);
	}
	else {
		$response->{$fh}->{'content'} = "File not found! Srsly.";
		$self->http_response($fh, "Not found", 404);
	}

}

sub http_header {

	my ($self, $fh, $key, $val) = @_;

	push @{$response->{$fh}->{'headers'}}, [$key,$val];

}

sub http_response {

	my ($self, $fh, $msg, $code) = @_;

	$self->http_out($fh, "HTTP/1.0 $code $msg\n");

	my %pushed = ();

	if (defined @{$response->{$fh}->{'headers'}} && @{$response->{$fh}->{'headers'}}) {
		for my $header (@{$response->{$fh}->{'headers'}}) {
			$pushed{lc($header->[0])}++;
			$self->http_out($fh, $header->[0].": ".$header->[1]."\n");
		}
	}

	$self->http_out($fh, "Connection: close\n");
	$self->http_out($fh, "X-Powered-By: MikroTik Toolkit Embedded Webserver. MTEW?!\n");
	$self->http_out($fh, "Content-Length: ".length( $response->{$fh}->{'content'} ). "\n");
	$self->http_out($fh, "\n");
	$self->http_out($fh, $response->{$fh}->{'content'});

	$self->http_close($fh);
}

sub http_template {
	my ($self, $template, $vars) = @_;
	my $output;
	$tt->process($template, $vars, \$output) or die $tt->error(), "\n";
	return $output;

}







1;
