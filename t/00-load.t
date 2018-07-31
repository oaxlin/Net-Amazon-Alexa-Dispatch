#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 13;

use_ok('Net::Amazon::Alexa::Dispatch');

my $json = {};
$json->{'request'}->{'timestamp'} = `date --utc '+%FT%H:%M:%SZ'`; chomp($json->{'request'}->{'timestamp'});
$json->{'request'}->{'intent'}->{'name'} = 'HelloIntent';
$json->{'session'}->{'user'}->{'accessToken'} = 'testing';


my $ret;
my $alexa = Net::Amazon::Alexa::Dispatch->new({
    skillName=>'YourSkillName',
    "Net::Amazon::Alexa::Dispatch" => {
        "alexa_token" => "testing",
        dispatch => ["Net::Amazon::Alexa::Dispatch"],
    },
});
isa_ok($alexa,'Net::Amazon::Alexa::Dispatch');


$ret = eval{ $alexa->run_method($json)} || $@;
ok($ret->{'response'}->{'outputSpeech'}->{'text'},'HelloIntent worked') or diag explain $ret;


{
    local $json->{'session'}->{'user'}->{'accessToken'} = 'bad token';
    $ret = eval{ $alexa->run_method($json)} || $@;
    isa_ok($ret, 'Throw', 'Got a Throw error for an invalid accessToken request') or diag explain $ret;
    ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;
}


{
    local $json->{'session'}->{'user'}->{'accessToken'};
    delete $json->{'session'}->{'user'}->{'accessToken'};
    $ret = eval{ $alexa->run_method($json)} || $@;
    isa_ok($ret, 'Throw', 'Got a Throw error for a request missing the accessToken') or diag explain $ret;
    ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;
}


{
    local $json->{'session'}->{'user'}->{'accessToken'} = 'bad token';
    $ret = eval{ $alexa->run_method($json)} || $@;
    isa_ok($ret, 'Throw', 'Got a Throw error for an invalid accessToken') or diag explain $ret;
    ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;
}


{
    local $json->{'request'}->{'timestamp'} = '2000-04-20T10:08:10Z';
    $ret = eval{ $alexa->run_method($json)} || $@;
    isa_ok($ret, 'Throw', 'Got a Throw error for an invalid timestamp request') or diag explain $ret;
    ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;
}


{
    local $json->{'request'}->{'intent'}->{'name'};
    delete $json->{'request'}->{'intent'}->{'name'};
    $ret = eval{ $alexa->run_method($json)} || $@;
    isa_ok($ret, 'Throw', 'Got a Throw error for an invalid intent->name in request') or diag explain $ret;
    ok($ret->{'alexa_safe'},'Throw was flagged alexa_safe') or diag explain $ret;
}


