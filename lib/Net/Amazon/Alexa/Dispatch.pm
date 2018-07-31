package Net::Amazon::Alexa::Dispatch;
use strict;
use warnings;
use JSON;
use Net::OAuth2;
use Time::Piece;
use URI::Escape;
use Throw qw{throw};

my $me = 'Net::Amazon::Alexa::Dispatch';

=head1 NAME

Net::Amazon::Alexa::Dispatch - Perl extensions for creating an Alexa skill

=head1 SYNOPSIS

  use Net::Amazon::Alexa::Dispatch;

  my $alexa = Net::Amazon::Alexa::Dispatch->new({
      skillName=>'YourSkillName',
      configFile=>'/home/oaxlin/config_alexa.json',
      dispatch=>[
          'Net::Amazon::Alexa::SomePlugin',
          'Net::Amazon::Alexa::AnotherPlugin'
      ],
    });
  $alexa->run_method($json);

=head1 DESCRIPTION

A Perl module which provides a simple and lightweight interface to the Amazon
Alexa Skills Kit

=head1 METHODS

A list of methods available

=head2 new

Create a new instance of Disptach.

All options can be passed into the new directly, or loaded from the "configFile"

=over

=over

=item configFile

OPTIONAL - The path to a perl evalable config file.

=item skillName

The name you wish to give this Alexa skill.  Used when displaying documentation.

Defaults to "Alexa Skill" if nothing is configured.

=item dispatch [array]

Any additional plugins you wish to dispatch to.  If you do not include any plugins then this module will only be able to perform Hello requests.

Plugins added during "new" will be processed before any in a config file.

If multiple plugins share the same method calls, the one listed first will be used.

Please note all plugins must use the same token for authentication

=back

=back

=cut

sub new {
    my $class = shift;
    my $args = shift;
    my $dispatch = $args->{'dispatch'};
    $dispatch = [$dispatch] if $dispatch && !ref $dispatch;
    my $config = {'Net::Amazon::Alexa::Dispatch'=>{}};
    if ($args->{'configFile'}) {
        local $/;
        open( my $fh, '<', $args->{'configFile'} )  or die "unable to close: $!";
        my $text = <$fh>;
        close $fh or die "unable to close: $!";
        my $temp_config = eval $text; ## no critic
        $config = $temp_config if ref $temp_config eq 'HASH' && exists $temp_config->{'Net::Amazon::Alexa::Dispatch'};
    }
    $config = $args if ref $args->{'Net::Amazon::Alexa::Dispatch'} eq 'HASH';
    push @{$dispatch}, @{$config->{'Net::Amazon::Alexa::Dispatch'}->{'dispatch'}} if ref $config->{'Net::Amazon::Alexa::Dispatch'}->{'dispatch'} eq 'ARRAY';
    my $node = {
        configFile => $args->{'configFile'},
        skillName => $args->{'skillName'} // $config->{'Net::Amazon::Alexa::Dispatch'}->{'skillName'} // 'Alexa Skill',
        dispatch => $dispatch,
        config => $config,
    };
    return bless $node, $class;
}

sub _find_module {
    # loops through all dispatch modules looking for a method match
    my $self = shift;
    my $method = shift;
    if ($method) {
        foreach my $module (@{$self->{'dispatch'}}) {
            eval "require $module" or throw "Skill plugin failed to initialize", { ## no critic
                                          cause => $@,
                                          intent_module => $module,
                                          alexa_safe => 1,
                                      }; ## no critic
            my $prefix = eval{ $module->intent_prefix } // '';
            my $full_method = $prefix.$method;
            return ($module,$full_method) if $module->can($full_method);
        }
    }
    throw "Unknown intent", {
        cause => 'Intent not found/configured',
        intent_method => $method,
        alexa_safe => 1,
    };
}

=head2 run_method

Parses the Amazon data and routes it to the appropriate module/method.

=over

=over

=item $json

Raw json data from Amazon.

=back

=back

=cut

sub run_method {
    my ($self, $json) = @_;

    # this really should be run well before a run_method is called
    # but just in case it wasn't we run it here
    $self->alexa_authenticate_json($json);

    my $ret = eval {
        my $method = $json->{'request'}->{'intent'}->{'name'};
        my ($module,$full_method) = $self->_find_module($method);
        warn "$module->$method\n"; # this warn is intentional, it creates a simple access_log type of entry

        my $obj = eval{ $module->new($self->{'config'}); } or throw "Skill plugin could not be initialized", {
                                                               cause => $@,
                                                               alexa_safe => 1,
                                                           };
        $obj->$full_method($json);
    };
    my $e = $@;
    if ($e) {
        throw $e if ref $e eq 'Throw' && $e->{'alexa_safe'};
        $ret = { error => $e };
    }
    return $self->msg_to_hash($ret);
}

=head2 intent_prefix

Simply returns the intent_prefix value used by this module
The default is "alexa_intent_"

Without intent_prefix all methods in a module will be exposed.  Setting this
value will expose only methods that begin with the prefix

=cut

sub intent_prefix { return 'alexa_intent_' }

=head2 skill_name

Simply returns the value configured in Config->skillName

Defaults to "Alexa Skill" if nothing is configured.

=cut

sub skill_name {
    return shift->{'skillName'} // "Alexa Skill";
}

=head2 alexa_authenticate_params ( $param )

Used by the dispatcher to grant access.

If authentication is successful this method should return the token.

If authentication fails, this method return undef or die.

=over

=over

=item $param

A hash containing the name/value pairs of all data submitted with the alexa skill request.

Values provided by Amazon include
  response_type
  redirect_uri
  state
  client_id

Values expected by Net::Amazon::Alexa::Dispatch
  Password

You can use any additional paramaters as needed.  So long as they do not conflict with the names above.

=back

=back

=cut

sub alexa_authenticate_params {
    my ($self,$param) = @_;
    # TODO use something better than the password as a token
    my $token = $self->{'config'}->{'Net::Amazon::Alexa::Dispatch'}->{'alexa_token'};
    throw "No token configured in Config->Net::Amazon::Alexa::Dispatch->alexa_token", {
        cause => "Token not found",
        alexa_safe => 1,
    } unless defined $token;
    return $token if $token eq ($param->{'Password'}//'');
    return undef;
}

=head2 alexa_authenticate_json ( $json )

Used by the dispatcher to grant access.

If authentication is successful this method should return a true value.

If authentication fails, this method return undef or die.

=over

=over

=item $json

Raw json data from Amazon.

=back

=back

=cut

sub alexa_authenticate_json {
    my ($self, $json) = @_;
    my $method = $json->{'request'}->{'intent'}->{'name'};
    my $token = $json->{'session'}->{'user'}->{'accessToken'};

    my $t = $json->{'request'}->{'timestamp'} || throw "Missing request timestamp, try again", {
                                                    cause => "Missing timestamp from json request",
                                                    alexa_safe => 1,
                                                 };
    $t =~ s/Z$/ +0000/;

    my $dateformat = '%Y-%m-%dT%H:%M:%S %z';
    my $date1 = eval{ Time::Piece->strptime($t, $dateformat)} || throw "Invalid request timestamp, try again", {
                                                                     cause => "Malformed timestamp",
                                                                     timestamp => $t,
                                                                     alexa_safe => 1,
                                                                 };
    my $d_txt = `/bin/date +'$dateformat'`;
    chomp($d_txt);
    my $date2 = eval{ Time::Piece->strptime($d_txt, $dateformat) } || throw "Could not read local time, try again", {
                                                                          cause => "Malformed timestamp",
                                                                          timestamp => $d_txt,
                                                                          alexa_safe => 1,
                                                                      };
    throw "Request too old, try again", {
        cause => "Timestamp out of range",
        timestamp1 => $t,
        timestamp2 => $d_txt,
        alexa_safe => 1,
    } if abs($date1->strftime('%s') - $date2->strftime('%s')) > ($self->{'config'}->{'Net::Amazon::Alexa::Dispatch'}->{'max_token_age'} // 500);

    # TODO use something better than the password as a token
    my $dispatcher_token = $self->{'config'}->{'Net::Amazon::Alexa::Dispatch'}->{'alexa_token'};
    throw "No token configured in Config->Net::Amazon::Alexa::Dispatch->alexa_token", {
        cause => 'Missing alexa_token',
        alexa_safe => 1,
    } unless defined $dispatcher_token;
    throw "Please open the Alexa skill from your phone to re link your account, then try again", {
        cause => 'token mismatch',
        alexa_safe => 1,
    } unless defined $token && $token eq $dispatcher_token;
    1;
}

=head2 alexa_intent_HelloIntent( $args, $json )

A sample intent action that an Alexa skill can perform.

=over

=over

=item $json

Raw json data from Amazon.

=back

=back

The return value should be the text that you wish Alexa to say in response to the
skill request.

=cut

sub alexa_intent_HelloIntent {
    my ($self, $json) = @_;
    my $nvp = $self->slots_to_hash($json); # not really needed, but good for example purposes
    return "Alexa dispatcher says hello";
}

=head2 alexa_intent_HelloIntent__meta

Basic meta information about your skill.  This will be used by the automatic
documentation to make it easier for others to create their own skills using your
plugin

=cut

sub alexa_intent_HelloIntent__meta {
    return {
        utterances => [
            'hello',
        ],
        # slots => [{name=>"someName",type=>"AMAZON.NUMBER"},{name=>"anotherName",type=>"customName",values=>[1,2,3]}]
    }
}

=head2 slots_to_hash

Takes in the Alexa $json data and returns a simple hash with key/value pairs

If your JSON looks something like this

  {
    "request": {
      "type": "IntentRequest",
      "intent": {
        "name": "HelloIntent",
        "slots": {
          "bravia_location": {
            "name": "bravia_location",
            "value": "upstairs"
          }
        }
      }
    }
  }

Then $self->slots_to_hash($json) will return a hash containing

  {
    "bravia_location" => "upstairs",
  }

=cut

sub slots_to_hash {
    my ($self, $json) = @_;
    my $easy_args = {}; # simplify pulling args out of the Amazon api
    if (ref $json->{'request'} eq 'HASH'
        && exists $json->{'request'}->{'intent'}
        && ref $json->{'request'}->{'intent'} eq 'HASH'
        && exists $json->{'request'}->{'intent'}->{'slots'}
    ) {
        foreach my $key (keys %{$json->{'request'}->{'intent'}->{'slots'}}) {
            $easy_args->{$key} = $json->{'request'}->{'intent'}->{'slots'}->{$key}->{'value'};
        }
    }
    return $easy_args;
}

=head2 msg_to_hash

Parses the message and turns it into a hash suitable to be JSONified for Alexa

=over

=over

=item $ret

Raw response, coulde be one of

  1) Already existing well formatted Alexa HASH response

  2) Simple text

  3) Throw object, with alexa_safe=>1 set

Be careful to not send die text to this method as they look just like simple text.  A good way to "escape" die messages is to return them like this

  return { error => $@ } if $@;

=item $default

This text will be used if the value of $ret does not fit the above criteria

If no default is provided then 'Skill returned invalid response data' will be used

=back

=back

=cut

sub msg_to_hash {
    # simple response wrapper for alexa
    # can take a full valid hash, or a simple scalar
    my $self = shift;
    my $ret = shift;
    my $default = shift || 'Skill returned invalid response data';
    return $ret if ref $ret eq 'HASH'
        && defined $ret->{'version'}
        && defined $ret->{'sessionAttributes'}
        && ref $ret->{'response'} eq 'HASH'
        && ref $ret->{'response'}->{'outputSpeech'} eq 'HASH'
        && defined $ret->{'response'}->{'outputSpeech'}->{'type'}
        && defined $ret->{'response'}->{'outputSpeech'}->{'text'}
        && defined $ret->{'response'}->{'shouldEndSession'};

    while (ref $ret eq 'HASH'
        && scalar keys %{$ret} == 1
        && exists $ret->{'error'}
        && ((ref $ret->{'error'}) =~ /^(HASH|Throw)$/)
    ) {
        # catch an error stuffed into a simple hash
        $ret = $ret->{'error'};
    }

    if (ref $ret eq 'Throw' && $ret->{'alexa_safe'}) {
        # allow "alexa_safe" errors
        $ret = $ret->{'error'};
    }

    if (ref $ret) {
        # only very specific refs are allowed
        require Data::Dumper;
        warn "Invalid object response", eval{Data::Dumper::Dumper $ret;};
        $ret = $default;
    }

    return {
        version => '1.0',
        sessionAttributes=>{},
        response=>{
            outputSpeech => {
                type => 'PlainText',
                text => "$ret",
            },
            shouldEndSession => JSON::true,
        },
    };
}

sub config {
    my $self = shift;
    my $config = $self->{'config'}->{ref $self};
    throw "Missing ".(ref $self)." config", {
        alexa_safe => 1,
    } unless $config;
    return $config;
}

1;
