# ---+ Extensions
# ---++ ImageGeneratorPlugin
# This is the configuration used by the <b>ImageGeneratorPlugin</b>.

# **STRING**
# secret used to sign rest api requests using Digest::HMAC
$Foswiki::cfg{ImageGeneratorPlugin}{Secret} = '';

# **STRING**
# default font for images
$Foswiki::cfg{ImageGeneratorPlugin}{Font} = 'Helvetica';

# **STRING**
# default image type 
$Foswiki::cfg{ImageGeneratorPlugin}{ImageType} = 'jpeg';

1;
