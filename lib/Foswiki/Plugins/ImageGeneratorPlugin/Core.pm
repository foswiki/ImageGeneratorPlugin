# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# ImageGeneratorPlugin is Copyright (C) 2022-2024 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::ImageGeneratorPlugin::Core;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Plugins ();
use Image::Magick;
use Digest::MD5 ();
use Digest::HMAC ();
use MIME::Base64 ();
use Encode ();
use Error qw(:try);

sub new {
  my $class = shift;
  my $session = shift || $Foswiki::Plugins::SESSION;

  my $this = bless({
    hueFrom => 0,
    hueTo => 359,
    seed => "",
    saturation => [50, 65, 80],
    lightness => [35, 50, 65, 80],
    light => [0, 0, 100],
    dark => [0, 0, 0],
    font => $Foswiki::cfg{ImageGeneratorPlugin}{Font} // 'Helvetica',
    imageType => $Foswiki::cfg{ImageGeneratorPlugin}{ImageType} // 'jpeg',
    secret => $Foswiki::cfg{ImageGeneratorPlugin}{Secret} // "foobar",
    @_
  }, $class);


  $this->{session} = $session;

  return $this;
}

sub DESTROY {
  my $this = shift;

  undef $this->{session};
  undef $this->{hmac};
  undef $this->{availableFonts};
}

sub hmac {
  my $this = shift;

  $this->{hmac} = Digest::HMAC->new( 
    $this->{secret}, 
    "Digest::MD5"
  ) unless defined $this->{hmac};

  return $this->{hmac};
}

sub getCodeForParams {
  my ($this, $params) = @_;

  $this->hmac->reset();

  foreach my $key (sort keys %$params) {
    next if $key =~ /^_/ || $key eq "k";
    my $val = $params->{$key};
    $val = join(", ", @$val) if ref($val);
    my $str = $key."=".$val;
    $this->hmac->add($str);
  }

  return MIME::Base64::encode_base64url($this->hmac->digest);
}

sub sign {
  my ($this, $params) = @_;

  return $params->{k} = $this->getCodeForParams($params);
}

sub validate {
  my ($this, $params) = @_;

  my $oldCode = $params->{k};
  return 0 unless $oldCode;

  my $newCode = $this->getCodeForParams($params);

  return $oldCode eq $newCode ? 1:0;
}

sub validateRequest {
  my ($this, $request) = @_;
  
  my %params = ();
  foreach my $key ($request->param()) {
    $params{$key} = $request->param($key);
  }  

  return $this->validate(\%params);
}

sub GENIMAGEURL {
  my ($this, $params, $topic, $web) = @_;

  $params->{text} //= $params->{_DEFAULT} // "";

  my %urlParams = ();
  foreach my $key (%$params) {
    next if $key =~ /^_/;
    my $val = $params->{$key};
    next unless defined $val;
    $val = Foswiki::Func::decodeFormatTokens($val);
    $val = ($val =~ /%/) ? Foswiki::Func::expandCommonVariables($val) : $val;
    $urlParams{$key} = $val;
  }

  $this->sign(\%urlParams);

  # SMELL: not using this as this results in unicode double-encoding in Foswiki::urlEncode
  #return Foswiki::Func::getScriptUrl("ImageGeneratorPlugin", "process", "rest", %urlParams);

  return $this->getScriptUrlPath("ImageGeneratorPlugin", "process", "rest") . _makeParams(\%urlParams);
}

sub getScriptUrlPath {
  my $this = shift;
  my $path1 = shift;
  my $path2 = shift;
  my $script = shift;

  return $this->{session}->getScriptUrl(0, $script, $path1, $path2, @_);
}

sub getAvailableFonts {
  my $this = shift;

  unless ($this->{availableFonts}) {
    my $mage = Image::Magick->new();
    $this->{availableFonts} = {map {$_ => 1} $mage->QueryFont()};
  }

  return keys %{$this->{availableFonts}};
}

sub isFontAvailable {
  my ($this, $font) = @_;

  $this->getAvailableFonts();

  return exists $this->{availableFonts}{$font};
}

sub GENIMAGE {
  my ($this, $params, $topic, $web) = @_;

  my $error;
  try {
    $this->initParams($params);
  } catch Error with {
    $error = shift;
  };
  return _inlineError($error) if $error;

  my $fileName = _getFilePath($params);
  my $url = _getPubUrl($params);
  my $request = Foswiki::Func::getRequestObject();
  my $refresh = $request->param('refresh') || '';
  $refresh = ($refresh =~ /^(on|1|yes|img|image)$/g) ? 1 : 0;

  unless (-e $fileName && !$refresh) {
    try {
      my $image = $this->render($params);
      $image->Write($fileName);
    } catch Error with {
      $error = shift;
      #print STDERR "ERROR: ImageGeneratorPlugin - $error\n";
    };

    return _inlineError($error) if $error;
  }

  my $className = "class=\"genImage";
  $className .= " $params->{class}" if $params->{class};
  $className .= '"';

  $params->{title} //= "";
  $params->{alt} //= $params->{title};

  my $title = $params->{title} ? 'title="'.$params->{title}.'"' : "";
  my $alt = $params->{alt} ? 'alt="'.$params->{alt}.'"' : "";
  my $style = $params->{style} ? 'style="'.$params->{style}.'"' : "";
  my $align = $params->{align} ? 'align="'.$params->{align}.'"' : "";

  my $format = $params->{format} // '<img src="$url" width="$width" height="$height" $class $align $title $alt $style />';

  $format =~ s/\$url\b/$url/g;
  $format =~ s/\$width\b/$params->{width}/g;
  $format =~ s/\$height\b/$params->{height}/g;
  $format =~ s/\$title\b/$title/g;
  $format =~ s/\$class\b/$className/g;
  $format =~ s/\$alt\b/$alt/g;
  $format =~ s/\$align\b/$align/g;
  $format =~ s/\$style\b/$style/g;

  return Foswiki::Func::decodeFormatTokens($format);
}

sub handleREST {
  my ($this, $subject, $verb, $response) = @_;

  my $request = Foswiki::Func::getRequestObject();

  unless ($this->validateRequest($request)) {
    return "ERROR: invalid request to ImageGeneratorPlugin/process\n";
  }

  my $params = $this->initParamsFromRequest();
  my $fileName = _getFilePath($params);
  my $url = _getPubUrl($params);

  my $refresh = $request->param('refresh') || '';
  $refresh = ($refresh =~ /^(on|1|yes|img|image)$/g) ? 1 : 0;

  unless (-e $fileName && !$refresh) {
    my $image = $this->render($params);
    $image->Write($fileName);
  }

  Foswiki::Func::redirectCgiQuery($request, $url);

  my $expireHours = $refresh?0:8;
  $response->header(-cache_control => "max-age=".($expireHours * 60 * 60));

  return "";
}

sub initParamsFromRequest {
  my $this = shift;

  my $request = Foswiki::Func::getRequestObject();
  my $params = {};
  foreach my $key ($request->param()) {
    $params->{$key} = $request->param($key);
  }

  return $this->initParams($params);
}

sub initParams {
  my ($this, $params) = @_;

  return $params if $params->{_inited};

  my $text = $params->{text} // $params->{_DEFAULT} // "";
  $text = Foswiki::Func::decodeFormatTokens($text);
  $params->{text} = $text =~ /%/ ? Foswiki::Func::expandCommonVariables($text) : $text;

  my $label = $params->{label};

  unless (defined $label) {
    my $from = $params->{from} // "firstletter";

    if ($from eq 'firstletter') {
      $label = uc(substr($params->{text}, 0, 1));
    }

    if ($from eq 'initials') {
      $label = "";

      while ($params->{text} =~ /(\w+)\W*/g) {
        $label .= substr($1, 0, 1);
      }
      $label = uc($label);
    }
  }
  $params->{label} = $label;

  $params->{width} //= "150";
  $params->{height} //= "150";

  $params->{huefrom} //= $this->{hueFrom};
  $params->{hueto} //= $this->{hueTo};
  $params->{seed} //= $this->{seed};
  $params->{saturation} //= $this->{saturation};
  $params->{saturation} = split(/\s*,\s*/, $params->{saturation}) unless ref($params->{saturation});
  $params->{lightness} //= $this->{lightness};
  $params->{lightness} = split(/\s*,\s*/, $params->{lightness}) unless ref($params->{lightness});
  $params->{light} //= $this->{light};
  $params->{light} = split(/\s*,\s*/, $params->{light}) unless ref($params->{light});
  $params->{dark} //= $this->{dark};
  $params->{dark} = split(/\s*,\s*/, $params->{dark}) unless ref($params->{dark});
  $params->{font} //= $this->{font};
  $params->{type} //= $this->{imageType};
  $params->{_inited} = 1;

  throw Error::Simple("unknown font") #: use one of ". join(", ", $this->getAvailableFonts))
    unless $this->isFontAvailable($params->{font});

  return $params;
}

sub render {
  my ($this, $params) = @_;

  $this->initParams($params);

  my $bgColor = _getHSL($params);
  my $fgColor = _isLight(_hsl2rgb($bgColor)) ? $this->{dark} : $this->{light};

  $bgColor = _formatHSL($bgColor);
  $fgColor = _formatHSL($fgColor);

  #print STDERR "bg=$bgColor, fg=$fgColor\n";

  my $image = Image::Magick->new();

  my $e;

  $e = $image->Set(
    size => $params->{width} . "x" . $params->{height}
  );
  throw Error::Simple($e) if $e;

  $e = $image->ReadImage("canvas:$bgColor");
  throw Error::Simple($e) if $e;

  my $pointSize = abs($params->{width} / (length($params->{label}) + 1));
  #print STDERR "width=$params->{width}, pointSize=$pointSize\n";

  $e = $image->Annotate(
    text => $params->{label},
    fill => $fgColor,
    gravity => 'Center',
    antialias => 'true',
    pointsize => $pointSize,
    font => $params->{font}, # SMELL: or use family, style, stretch, weight, density
  );

  if ($e) {
    throw Error::Simple($e);
  }

  return $image;
}

### static helper ####

sub _getFileName {
  my $params = shift;

  my $digest = Digest::MD5->new();
  foreach my $key (sort keys %$params) {
    next if $key =~ /^_/;
    my $val = $params->{$key};
    next unless defined $val && $val ne "";
    $val = join(", ", @$val) if ref($val);

    #print STDERR "adding $key=$val\n";
    $digest->add(Encode::encode_utf8($val));
  }

  my $hex = $digest->hexdigest;
  return "picture-$hex.".$params->{type};
}

sub _getFilePath {
  my $fileName = _getFileName(@_);
  return $Foswiki::cfg{PubDir} . "/" . $Foswiki::cfg{SystemWebName} . "/ImageGeneratorPlugin/cache/$fileName";
}

sub _getPubUrl {
  my $fileName = _getFileName(@_);
  return $Foswiki::cfg{PubUrlPath} . "/" . $Foswiki::cfg{SystemWebName} . "/ImageGeneratorPlugin/cache/$fileName";
}

# from https://www.w3schools.com/lib/w3color.js
sub _hsl2rgb {
  my $hsl = shift;

  my ($hue, $sat, $light) = @$hsl;

  $hue /= 60;
  $sat /= 100 if $sat > 1;
  $light /= 100 if $light > 1;

  my $t2 = ($light <= 0.5) ? $light * ($sat + 1) : $light + $sat - ($light * $sat);
  my $t1 = $light * 2 - $t2;
  my $r = _hue2rgb($t1, $t2, $hue + 2) * 255;
  my $g = _hue2rgb($t1, $t2, $hue) * 255;
  my $b = _hue2rgb($t1, $t2, $hue - 2) * 255;

  return [sprintf("%.0f", $r), sprintf("%.0f", $g), sprintf("%.0f", $b)];
}

sub _hue2rgb {
  my ($t1, $t2, $hue) = @_;

  $hue += 6 if $hue < 0;
  $hue -= 6 if $hue >= 6;
  return ($t2 - $t1) * $hue + $t1 if $hue < 1;
  return $t2 if $hue < 3;
  return ($t2 - $t1) * (4 - $hue) + $t1 if $hue < 4;
  return $t1;
}

sub _isLight {
  my $rgb = shift;

  # YIQ equation from http://24ways.org/2010/calculating-color-contrast
  my $yiq = (($rgb->[0] * 299) + ($rgb->[1] * 587) + ($rgb->[2] * 114)) / 1000;

  #print STDERR "rgb=@$rgb, yiq=$yiq\n";
  return $yiq > 128;
}

sub _formatHSL {
  my $hsl = shift;

  return sprintf("hsl(%d, %d%%, %d%%)", @$hsl);
}

sub _getHSL {
  my $params = shift;

  my $hash = _getHash($params->{text}, $params);

  return [_getHue($hash, $params), _getSaturation($hash, $params), _getLightness($hash, $params)];
}

sub _getHue {
  my ($hash, $params) = @_;

  return $params->{huefrom} + $hash % abs($params->{hueto} - $params->{huefrom});
}

sub _getHash {
  my ($text, $params) = @_;

  my $hash = 0;
  foreach my $c (split //, $text . $params->{seed}) {
    $hash = ord($c) + (($hash << 5) - $hash);
  }

  return $hash;
}

sub _getSaturation {
  my ($hash, $params) = @_;

  if (ref($params->{saturation})) {
    return $params->{saturation}[$hash % scalar(@{$params->{saturation}})];
  } 

  return $params->{saturation};
}

sub _getLightness {
  my ($hash, $params) = @_;

  if (ref($params->{lightness})) {
    return $params->{lightness}[$hash % scalar(@{$params->{lightness}})];
  } 

  return $params->{lightness};
}

sub _makeParams {
  my $params = shift;

  my @results = ();

  foreach my $key (keys %$params) {
    my $val = $params->{$key};
    push @results, "$key=". _urlEncode($val);
  }

  return "" unless @results;
  return "?" . join("&", @results);
}

# same as Foswiki::urlEncode but without the encode_utf8
sub _urlEncode {
  my $text = shift;

  $text =~ s{([^0-9a-zA-Z-_.:~!*/])}{sprintf('%%%02x',ord($1))}ge;

  return $text;
}

sub _inlineError {
  my $text = shift;

  $text =~ s/ at .*$//s;

  return "<span class='foswikiAlert'>ERROR: $text</span>";
}

1;
