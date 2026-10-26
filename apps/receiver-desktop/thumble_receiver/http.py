"""Bounded HTTPS JSON requests with no redirects or persisted credentials."""
import json
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from urllib.error import HTTPError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request_json(url, method='GET', token=None, body=None, form=None, timeout=10, limit=262144):
    if urlsplit(url).scheme != 'https':
        raise ValueError('HTTPS required')
    headers = {'Accept': 'application/json', 'Cache-Control': 'no-store'}
    data = None
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if form is not None:
        data = urlencode(form).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    elif body is not None:
        data = json.dumps(body, allow_nan=False, separators=(',', ':')).encode()
        headers['Content-Type'] = 'application/json'
    try:
        response = build_opener(NoRedirect()).open(Request(url, data=data, headers=headers, method=method), timeout=timeout)
    except HTTPError as error:
        error.close()
        raise
    with response:
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError('Response exceeds size limit')
        value = json.loads(data)
        if not isinstance(value, dict):
            raise ValueError('Expected JSON object')
        return value
