package MTT::Web;

use strict;
use Data::Dumper;
use HTTP::Tiny;
use IO::Select;
use MIME::Base64;
use Template;

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
				binmode($fhnew, ":encoding(UTF-8)");
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
	chomp $output;
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
	

	###############################################################

	if ($location eq "/") {
		push @{$response->{$fh}->{'headers'}}, ["Content-Type","text/html; charset=UTF-8"];
		$response->{$fh}->{'content'} = $self->http_template(
			"index.tt", {
				'data' => "test",
			}
		);
	}

	elsif ($location =~ /\/static\/([a-z]+\.[a-z]+)$/) {
		$response->{$fh}->{'content'} = Dumper $main::log;
	}

	elsif ($location eq "/syslog") {
		$response->{$fh}->{'content'} = Dumper $main::log;
	}
	elsif ($location eq "/config") {
		$response->{$fh}->{'content'} = Dumper $main::config;
	}
	elsif ($location eq "/backup") {
		$response->{$fh}->{'content'} = Dumper $main::backup;
	}

	else { 
		$routed = 0; 
	}

	###############################################################

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

sub http_static_favicon {
	my ($self, $fh) = @_;
	my $data = "AAABAAEAEBAAAAAAAABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAD///8A3b3BAN29wQDdvcEA3b3BANy6vgDw4OUAuH1/YJAzMsThxssA3L/EANa1uADXtroA17a6ANe2ugD///8A////AN6+wgDevsIA3r7CAN27vwDr1toAzZ+jJoQfHv98EA3/rGhpePTq8ADkzdEA5MzRAOTM0QDkzNEA////AP///wDavMAA2rzAANm6vgDhyc0A6NXZAIwtLNCGISD/kDQz/30QD//LnaA8////AOvZ2wDt3N4A7dzeAP///wD///8A4MPGAODDxgDiyMsA6dTYAJhBQqSDHRv/kTU0/5AzMv+JKCf/hiEg9ti3ugbm0NQA27zAANy+wgD///8A////ANi3uADXtrcA69vbALyEhVh6DQv/kTU0/48yMf+PMjH/kTU0/4QfHf+PMTHI7NjcAOXKzQDfwcQA////AP///wDjys0A8OHlAMOQkzN8Dw7/jjAv/48yMf+PMjH/jzIx/48yMf+RNjX/fRMR/6pgYYbv298A5szPAP///wD///8A////APnu8wCQMzPehiIg/5A0M/+PMjH/jzIx/48yMf+PMjH/jzIx/48zMv9/FhT/wY2PQd7BxQD///8A////ANClqgCyb3FffhQS/5E2Nf+PMjH/jzIx4Y8yMVuPMjE6jzIxsI8yMf+QMzL/iCUj/48yMY6PMjEH////AP///wCPMjEHjzIxqYkoJv+PMjH/jzIx/48yMTOPMjEAjzIxAI8yMQCPMjG8jzIx/5A0M/+PMjHCjzIxAP///wD///8AjzIxII8yMamPMTD/jzIx/48yMe6PMjEAjzIxAI8yMQCPMjEAjzIxZI8yMf+PMjH/jzIx/48yMTb///8A////AI8yMQePMjGpjC0r/48yMf+PMjH/jzIxHY8yMQCPMjEAjzIxAI8yMZ+PMjH/jzIx/48yMamPMjEA////AP///wC+iI0Rn09Qj4McGv+QNDP/jzIx/48yMcGPMjEVjzIxAo8yMXePMjH/jzIx/44vLv+PMjGpjzIxB48yMQf///8AxZOXALuAgxeFIB7/jjEw/48yMf+PMjH/jzIx/o8yMf2PMjH/jzIx/5E2Nf9/FhT/qF9gg8mboAz///8A////AOHDxgDr1toAs3JzfoAWFP+PMjD/jzIx/48yMf+PMjH/jzIx/48yMf+FIB7/l0BAxuHGyQDlzdAA////AP///wDn0tMA7t3fAN/BxQCZQ0V5iCcl/4knJf+LKyr/ji8u/4cjIf+KKij/jS8uxMiXmw7hxckA17S2AP///wD///8A5MvNAOjS1ADburwAqmJlAJ9PURygT1GEkzk51pA0M+WfTk+nolVXPqNVVwDJmp0A2Le5ANi2uAD///8A/38AAP5/AAD8PwAA+B8AAPgPAADwBwAA4AcAAOGDAADDwwAAw+MAAMPDAADBwwAA4AMAAPAHAAD4DwAA/D8AAA==";
	$self->http_header($fh, "Content-Type","image/ico");
	return decode_base64($data);

}

sub http_template {
	my ($self, $template, $vars) = @_;
	my $output;
	$tt->process($template, $vars, \$output) or die $tt->error(), "\n";
	return $output;

}







1;
