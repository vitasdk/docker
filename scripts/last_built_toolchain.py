import json
try:
    import urllib2
except ImportError:
    # python3?
    import urllib.request as urllib2

GITHUB_API_REPO = 'https://api.github.com/repos/vitasdk/buildscripts'
TAG_FORMAT = '%(branch)s-%(os)s-v2.%(build)s'


def fetch_succeeded_tags(branch='softfp', os='linux'):
    try:
        build_url = ''.join((GITHUB_API_REPO, '/actions/runs', '?branch=', branch, '&conclusion=success'))
        req = urllib2.Request(build_url)
        builds = json.load(urllib2.urlopen(req))
    except urllib2.HTTPError:
        # FIXME: need to check; network error
        return []
    except ValueError:
        # FIXME: need to check; json parse error
        return []

    for build in builds['workflow_runs']:
        yield TAG_FORMAT % dict(branch=branch, os=os, build=build['run_number'])


def last_built_toolchain(branch='softfp', os='linux'):
    for tag in fetch_succeeded_tags(branch=branch, os=os):
        try:
            release_url = ''.join((GITHUB_API_REPO, '/releases/tags/', tag))
            req = urllib2.Request(release_url)
            release = json.load(urllib2.urlopen(req))
        except urllib2.HTTPError:
            # FIXME: need to check; network error
            continue
        except ValueError:
            # FIXME: need to check; json parse error
            continue
        asset_download_url = release['assets'][0]['browser_download_url']
        if not asset_download_url:
            continue
        return asset_download_url


if __name__ == '__main__':
    import sys

    url = last_built_toolchain(*sys.argv[1:])
    if not url:
        raise SystemExit(1)
    print(url)
    raise SystemExit(0)
