#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 7;

use_ok('Net::Amazon::Alexa::Dispatch');

my $json = {};
$json->{'request'}->{'timestamp'} = `date --utc '+%FT%H:%M:%SZ'`; chomp($json->{'request'}->{'timestamp'});
$json->{'request'}->{'intent'}->{'name'} = 'HelloIntent';
$json->{'session'}->{'user'}->{'accessToken'} = 'bad token';



my $alexa = Net::Amazon::Alexa::Dispatch->new({
    skillName=>'YourSkillName',
    "Net::Amazon::Alexa::Dispatch" => {
        "alexa_token" => "testing",
        dispatch => ["Net::Amazon::Alexa::Dispatch"],
    },
});
isa_ok($alexa,'Net::Amazon::Alexa::Dispatch');



my $ret = eval{ $alexa->run_method($json)} || $@;
isa_ok($ret, 'Throw', 'Got a Throw error for an invalid accessToken request') or diag explain $ret;
ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;



$json->{'session'}->{'user'}->{'accessToken'} = 'testing';
$ret = eval{ $alexa->run_method($json)} || $@;
ok($ret->{'response'}->{'outputSpeech'}->{'text'},'HelloIntent worked') or diag explain $ret;



$json->{'request'}->{'timestamp'} = '2000-04-20T10:08:10Z';
$ret = eval{ $alexa->run_method($json)} || $@;
isa_ok($ret, 'Throw', 'Got a Throw error for an invalid timestamp request') or diag explain $ret;
ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;


