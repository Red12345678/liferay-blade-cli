#!/bin/bash

localNexusOpt=""
releaseType=""

# check the arguments first
while [ $# -gt 0 ]; do
	if [ "$1" = "snapshots" ] || [ "$1" = "release" ]; then
		releaseType="$1"
	elif [ "$1" = "--local" ]; then
		localNexusOpt="-PlocalNexus"
	fi
	shift
done

if [ "$releaseType" != "release" ] && [ "$releaseType" != "snapshots" ]; then
	echo "Must have one argument, either \"release\" or \"snapshots\"."
	exit 1
fi

# Setup a temp directory
timestamp=$(date +%s)
tmpDir="/tmp/$timestamp/"

mkdir -p $tmpDir

if [ -z "$repoHost" ]; then
	if [ "$localNexusOpt" = "-PlocalNexus" ]; then
		repoHost="http://localhost:8081"
	else
		repoHost="https://repository.liferay.com"
	fi
elif [ "$repoHost" = "http://localhost:8081" ]; then
    localNexusOpt="-PlocalNexus"
fi

# First clean local build folder to try to minimize variants

./gradlew -q --no-daemon --console=plain clean

if [ "$?" != "0" ]; then
   echo Failed clean.
   rm -rf /tmp/$timestamp
   exit 1
fi

# Publish the Remote Deploy Command jar

remoteDeployCommandPublishCommand=$(./gradlew -q --no-daemon --console=plain $localNexusOpt -P${releaseType} :extensions:remote-deploy-command:publish --info --scan)

if [ "$?" != "0" ] || [ -z "$remoteDeployCommandPublishCommand" ]; then
   echo $remoteDeployCommandPublishCommand
   echo Failed :extensions:remote-deploy-command:publish
   rm -rf /tmp/$timestamp
   exit 1
fi

# Publish the Maven Profile jar
mavenProfilePublishCommand=$(./gradlew -q --no-daemon --console=plain $localNexusOpt -P${releaseType} :extensions:maven-profile:publish --info --scan)

if [ "$?" != "0" ] || [ -z "$mavenProfilePublishCommand" ]; then
   echo $mavenProfilePublishCommand
   echo Failed :extensions:maven-profile:publish
   rm -rf /tmp/$timestamp
   exit 1
fi

# Grep the output of the previous command to find the url of the published jar
mavenProfilePublishUrl=$(echo "$mavenProfilePublishCommand" | grep Uploading | grep '.jar ' | grep -v -e '-sources' -e '-tests' | cut -d' ' -f2)

if [ "$?" != "0" ] || [ -z "$mavenProfilePublishUrl" ]; then
   echo Failed grepping for mavenProfilePublishUrl
   rm -rf /tmp/$timestamp
   exit 1
fi

# Download the just published jar in order to later compare it to the embedded maven profile that is in blade jar
mavenProfileJarUrl="$repoHost/nexus/content/groups/public/$mavenProfilePublishUrl"

curl -s "$mavenProfileJarUrl" -o /tmp/$timestamp/maven_profile.jar

if [ "$?" != "0" ]; then
   echo Downloading maven.profile jar failed.
   rm -rf /tmp/$timestamp
   exit 1
else
   echo "\nPublished $mavenProfileJarUrl"
fi

# Test the blade cli jar locally, but don't publish.
bladeCliJarCommand=$(./gradlew -q --no-daemon --console=plain $localNexusOpt -P${releaseType} --refresh-dependencies check --info --scan)

if [ "$?" != "0" ] || [ -z "$bladeCliJarCommand" ]; then
   echo $bladeCliJarCommand
   echo Failed :cli:jar
   rm -rf /tmp/$timestamp
   exit 1
fi

# now that we have the blade jar just built, lets extract the embedded maven profile jar and compare to the maven profile downloaded from nexus

embeddedMavenProfileJar=$(jar -tf cli/build/libs/blade.jar | grep "maven.profile-")

if [ -z "$embeddedMavenProfileJar" ]; then
   echo Failed to find embedded maven.profile jar in blade jar
   rm -rf /tmp/$timestamp
   exit 1
fi

unzip -p cli/build/libs/blade.jar "$embeddedMavenProfileJar" > /tmp/$timestamp/myExtractedMavenProfile.jar

diff -s /tmp/$timestamp/myExtractedMavenProfile.jar /tmp/$timestamp/maven_profile.jar

if [ "$?" != "0" ]; then
   echo Failed local blade.jar diff with downloaded maven profile jar.  The embedded maven profile jar and nexus maven profile jar are not identical
   rm -rf /tmp/$timestamp
   exit 1
fi

# Now lets go ahead and publish the blade cli jar for real since the embedded maven profile was correct

bladeCliPublishCommand=$(./gradlew -q --no-daemon --console=plain $localNexusOpt -P${releaseType} --refresh-dependencies :cli:publish --info --scan)

if [ "$?" != "0" ] || [ -z "$bladeCliPublishCommand" ]; then
   echo $bladeCliPublishCommand
   echo Failed :cli:publish
   rm -rf /tmp/$timestamp
   exit 1
fi

# Grep the output of the blade jar publish to find the url
bladeCliJarUrl=$(echo "$bladeCliPublishCommand" | grep Uploading | grep '.jar ' | grep -v -e '-sources' -e '-tests' | cut -d' ' -f2)

# download the just published jar in order to extract the embedded maven profile jar to compare to previously downloaded version from above (just to be double sure)
bladeCliUrl="$repoHost/nexus/content/groups/public/$bladeCliJarUrl"

curl -s "$bladeCliUrl" -o /tmp/$timestamp/blade.jar

if [ "$?" != "0" ]; then
   echo Downloading blade jar failed.
   rm -rf /tmp/$timestamp
   exit 1
else
   echo "\nPublished $bladeCliUrl"
fi

unzip -p /tmp/$timestamp/blade.jar "$embeddedMavenProfileJar" > /tmp/$timestamp/myExtractedMavenProfile.jar

diff -s /tmp/$timestamp/myExtractedMavenProfile.jar /tmp/$timestamp/maven_profile.jar

if [ "$?" != "0" ]; then
   echo Failed local blade.jar diff with downloaded maven profile jar.  The embedded maven profile jar and nexus maven profile jar are not identical
   rm -rf /tmp/$timestamp
   exit 1
fi

rm -rf /tmp/$timestamp