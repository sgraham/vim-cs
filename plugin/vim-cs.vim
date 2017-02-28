" Copyright 2017 The Chromium Authors. All rights reserved.
" Use of this source code is governed by a BSD-style license that can be
" found in the LICENSE file.
"
" Scott Graham <scott.vimcs@h4ck3r.net>

if !has('python')
  s:ErrMsg( "Error: Required vim compiled with +python" )
  finish
endif

" Embedding of chromium_code_search.py by Josh Karlin.
" https://github.com/karlinjf/ChromiumXRefs/ at 5f568e0ced34726ee98de1b5f2f1f0ad1f8dc668
" Minor porting was done to backport to Python2 since that's what my Vim has.

python << endpython
# Copyright 2017 Josh Karlin. All rights reserved.
# Use of this source code is governed by the Apache license found in the LICENSE
# file.

import argparse
import datetime
import getopt
import json
import sys
import tempfile
import threading
import time
import urllib
import urllib2

gFileCache = None

# A key/value store that stores objects to disk in temporary objects
# for 30 minutes.
class FileCache:
  def __init__(self):
    self.store = {}
    threading.Timer(15 * 60, self.gc).start();

  def put(self, url, data):
    f = tempfile.TemporaryFile();
    f.write(data);
    self.store[url] = (f, datetime.datetime.now());

  def get(self, url):
    if not url in self.store:
      return ''
    (f, timestamp) = self.store[url]
    f.seek(0);
    return f.read();

  def gc(self):
    threading.Timer(15 * 60, self.gc).start();
    expired = datetime.datetime.now() - datetime.timedelta(minutes=30);
    remove = []
    for url, (f, timestamp) in self.store.items():
      if timestamp < expired:
        remove.append(url)
    for url in remove:
      self.store.pop(url);

def cacheResponses(should_cache):
  global gFileCache
  if not should_cache:
    gFileCache = None;
    return
  if gFileCache:
    return
  gFileCache = FileCache();

# Retrieve the url by first trying to cache and falling back to the network.
def retrieve(url):
  global gFileCache

  if gFileCache:
    cached_response = gFileCache.get(url);
    if (cached_response):
      return cached_response.decode('utf8');
  try:
    response = urllib2.urlopen(url, timeout=3)
  except:
    return ''
  result = response.read()
  if gFileCache:
    gFileCache.put(url, result);
  return result.decode('utf8');

def getSignatureFor(src_file, method):
    url = ('https://cs.chromium.org/codesearch/json'
           '?annotation_request=b'
           '&file_spec=b'
           '&package_name=chromium'
           '&name={file_name}'
           '&file_spec=e'
           '&type=b'
           '&id=1'
           '&type=e'
           '&label='
           '&follow_branches=false'
           '&annotation_request=e')
    url = url.format(file_name=urllib.quote(src_file, safe=''))

    result = retrieve(url);
    if not result:
      sys.exit(2);

    result = json.loads(result)['annotation_response'][0]

    for snippet in result.get('annotation', []):
      if not 'type' in snippet:
        continue
      if 'xref_signature' in snippet:
        signature = snippet['xref_signature']['signature']
        if '%s(' % method in signature:
          return signature

      elif 'internal_link' in snippet:
        signature = snippet['internal_link']['signature']
        if '::%s' % method in signature or 'class-%s' % method in signature:
          return signature
    return ''

def getCallGraphFor(signature):
    url = ('https://cs.chromium.org/codesearch/json'
         '?call_graph_request=b'
         '&signature={signature}'
         '&file_spec=b'
         '&package_name=chromium'
         '&name=.'
         '&file_spec=e'
         '&max_num_results=500'
         '&call_graph_request=e')
    url = url.format(signature=urllib.quote(signature, safe=''))

    result = retrieve(url);
    if not result:
      sys.exit(2);

    result = json.loads(result)['call_graph_response'][0];
    node = result['node'];

    callers = [];
    last_signature = ''
    if not 'children' in node:
      return callers
    for child in node['children']:
      if child['signature'] == last_signature:
        continue
      if not 'snippet_file_path' in child:
        continue

      caller = {}
      caller['filename'] = child['snippet_file_path'];
      caller['line'] = child['call_site_range']['start_line']
      caller['col'] = child['call_site_range']['start_column']
      caller['text'] = child['snippet']['text']['text']
      caller['calling_method'] = child['identifier']
      caller['calling_signature'] = child['signature']
      last_signature = child['signature']
      caller['display_name'] = child['display_name']
      callers.append(caller)
    return callers

def getRefForMatch(filename, match):
  ref = {'filename': filename, 'line': match['line_number'], 'signature': match['signature']}
  if 'line_text' in match:
    ref['line_text'] = match['line_text']
  return ref;


def getXrefsFor(signature):
    url = ('https://cs.chromium.org/codesearch/json'
           '?xref_search_request=b'
           '&query={signature}'
           '&file_spec=b'
           '&name=.'
           '&package_name=chromium'
           '&file_spec=e'
           '&max_num_results=500'
           '&xref_search_request=e')
    url = url.format(signature=urllib.quote(signature, safe=''))
    result = retrieve(url);
    if not result:
      sys.exit(2);

    result = json.loads(result)['xref_search_response'][0]
    status = result['status']
    if not 'search_result' in result:
        return {}
    search_results = result['search_result']

    xrefs = {}

    for file_result in search_results:
        filename = file_result['file']['name']
        for match in file_result['match']:
            if match['type'] == 'HAS_DEFINITION':
                xrefs['definition'] = getRefForMatch(filename, match);
            elif match['type'] == 'HAS_DECLARATION':
                xrefs['declaration'] = getRefForMatch(filename, match);
            elif match['type'] == 'OVERRIDDEN_BY':
                xrefs.setdefault('overrides', []);
                xrefs['overrides'].append(getRefForMatch(filename, match));
            elif match['type'] == 'REFERENCED_AT':
                xrefs.setdefault('references', []);
                xrefs['references'].append(getRefForMatch(filename, match));
    return xrefs

def logAndExit(msg):
  print(msg);
  sys.exit(2);

if __name__ == "__main__":
  parser = argparse.ArgumentParser(description='Searches Chromium Code Search for X-Refs.')
  parser.add_argument('-p', '--path',
                      help='The path to this file starting with src/')
  parser.add_argument('-w', '--word',
                      help='The word to search for in the file denoted by the path argument. You must also specify -p')
  parser.add_argument('-s', '--signature',
                      help='A signature provided from a previous search. No -p or -w arguments required.')
  args = parser.parse_args()


  signature = args.signature;
  results = {}


  if not signature:
    if bool(args.path) ^ bool(args.word):
      print("Both path and word must be supplied if one is supplied");
      sys.exit(2);

    signature = getSignatureFor(args.path, args.word);
    results['signature'] = signature
    if not signature:
      logAndExit("Could not find signature for %s" % (args.word))

  results['xrefs'] = getXrefsFor(signature);
  results['callers'] = getCallGraphFor(signature);

  print(json.dumps(results))

endpython

" End of chromium_code_search.py.

python << endpython
import os
import vim

def FindHighestGitRoot(path):
  drive, tail = os.path.splitdrive(path)
  path_parts = tail.replace('\\', '/').split('/')
  result = '/'
  for part in path_parts:
    candidate = os.path.join(result, '.git')
    if os.path.isdir(candidate):
      return os.path.normpath(drive + result)
    result = os.path.join(result, part)
  return None

def RelativeToSrcRoot(path):
  highest_root = FindHighestGitRoot(path)
  src = os.path.normpath(os.path.join(highest_root, '..'))
  normed_path = os.path.normpath(path)
  if normed_path.startswith(src):
    src_path = normed_path[len(src)+1:].replace('\\', '/')
    return highest_root, src_path

def PrependRoot(src_relative_filename, highest_root):
  return os.path.normpath(
      os.path.join(highest_root, '..', src_relative_filename))
endpython

function! VimCs()
python << endpython
import tempfile
word = vim.eval('expand("<cword>")')
highest_root, path = RelativeToSrcRoot(vim.current.buffer.name)
signature = getSignatureFor(path, word)
xrefs = getXrefsFor(signature)
callers = getCallGraphFor(signature)
temp = tempfile.NamedTemporaryFile(delete=False)
print >>temp, 'Declaration:'
print >>temp, '  %s:%d: %s' % (PrependRoot(xrefs['declaration']['filename'],
                                           highest_root),
                               xrefs['declaration']['line'],
                               xrefs['declaration']['line_text'])
print >>temp, 'Definition:'
print >>temp, '  %s:%d: %s' % (PrependRoot(xrefs['definition']['filename'],
                                           highest_root),
                               xrefs['definition']['line'],
                               xrefs['definition']['line_text'])
print >>temp, 'Callers:'
for call in callers:
  print >>temp, '  %s:%d: %s [in %s]' % (PrependRoot(call['filename'],
                                                     highest_root),
                                         call['line'],
                                         call['text'],
                                         call['calling_method'])
temp.flush()
vim.command('cgetfile! ' + temp.name)
vim.command('copen')
endpython
endfunction

if !exists('g:vimcs_no_maps')
  map <silent> <C-\> :call VimCs()<cr>
endif
