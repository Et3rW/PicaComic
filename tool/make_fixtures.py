#!/usr/bin/env python3
"""Turn pages saved from the real sites into the small fixtures in test/fixtures.

The parsers are tested against real markup, but the fixtures should stay small
and should not copy other people's titles, user names or comments into this
repository. This script keeps the markup as the site sent it and only

  * drops all but the first few items of each list,
  * replaces titles, user names and comment text with placeholders,
  * removes scripts and styles the parsers do not read.

Usage: tool/make_fixtures.py <dir with captures> test/fixtures
See doc/source-tests.md for how to capture the pages.
"""
import json
import pathlib
import re
import sys

from bs4 import BeautifulSoup, Comment

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])


def soup(path):
    # Browsers keep the first of two attributes with the same name
    # (wnacg writes `class="title_sort" class="cc"`); do the same.
    return BeautifulSoup((src / path).read_text(encoding='utf-8'), 'html.parser',
                         on_duplicate_attribute='ignore')


def strip(doc, *selectors):
    for selector in selectors:
        for node in doc.select(selector):
            node.decompose()


def write(path, text):
    if not isinstance(text, str):
        # Page metadata and image captions repeat the title and description.
        strip(text, 'meta[name]', 'meta[property]')
        for img in text.select('img[alt]'):
            img['alt'] = ''
        text = str(text)
    target = out / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding='utf-8')
    print(f'{path}: {target.stat().st_size} bytes')


def retitle(doc, text):
    if doc.title:
        doc.title.string = text


def keep_first(nodes, count):
    for node in list(nodes)[count:]:
        node.decompose()


# ---------------------------------------------------------------- e-hentai

def eh_uploaders(doc, selector):
    for i, a in enumerate(doc.select(selector), 1):
        a.string = f'uploader{i}'
        a['href'] = f'https://e-hentai.org/uploader/uploader{i}'


def eh_list(name, rows, uploaders, count=3):
    doc = soup(f'eh/{name}.html')
    strip(doc, 'script', 'style', 'link', 'div#nb', 'div#toppane', 'div.dp', 'div.ip')
    keep_first(doc.select(rows), count)
    for i, title in enumerate(doc.select('.glink'), 1):
        title.string = f'Sample Gallery {i}'
    for img in doc.select('img[alt], img[title]'):
        img.attrs.pop('alt', None)
        img.attrs.pop('title', None)
    if uploaders:
        eh_uploaders(doc, uploaders)
    return doc


write('eh/list_compact.html', eh_list('nonh_l', 'table.itg > tr', 'td.gl4c a', count=4))
write('eh/list_minimal.html', eh_list('nonh_m', 'table.itg > tr', 'td.gl5m a', count=4))
write('eh/list_extended.html', eh_list('nonh_e', 'table.itg > tr', 'div.gl3e a'))
write('eh/list_thumbnail.html', eh_list('nonh_t', 'div.itg > div.gl1t', None))

doc = soup('eh/gallery.html')
strip(doc, 'style', 'link', 'div#nb', 'script[src]')
retitle(doc, 'Sample Gallery - E-Hentai Galleries')
doc.select_one('h1#gn').string = 'Sample Gallery'
if doc.select_one('h1#gj'):
    doc.select_one('h1#gj').string = 'サンプル'
eh_uploaders(doc, 'div#gdn a')
for i, comment in enumerate(doc.select('div.c1'), 1):
    for a in comment.select('div.c3 a'):
        a.string = f'commenter{i}'
        a['href'] = f'https://e-hentai.org/uploader/commenter{i}'
    comment.select_one('div.c6').string = f'Sample comment {i}'
strip(doc, 'meta[name]', 'meta[property]')
text = str(doc)
text = re.sub(r'var apikey = "[0-9a-f]+"', 'var apikey = "0123456789abcdef0123"', text)
write('eh/gallery.html', text)

doc = soup('eh/reader.html')
strip(doc, 'style', 'link', 'script[src]')
retitle(doc, 'Sample Gallery')
doc.select_one('h1').string = 'Sample Gallery'
write('eh/reader.html', doc)

# ------------------------------------------------------------------- wnacg

def ht_titles(doc):
    for i, a in enumerate(doc.select('div.info > div.title > a'), 1):
        a.string = f'样本标题{i}'
        if a.has_attr('title'):
            a['title'] = f'样本标题{i}'
    for img in doc.select('img[alt]'):
        img['alt'] = ''
    for a in doc.select('div.pic_box > a[title]'):
        a['title'] = ''


doc = soup('ht/home.html')
strip(doc, 'script', 'style', 'link', 'div.search', 'div#bodywrap > div.nav')
for block in doc.select('div.bodywrap'):
    keep_first(block.select('ul.cc > li'), 2)
for title in doc.select('div.title_sort'):
    for child in title.find_all('div', recursive=False):
        if not {'title_h2', 'r'} & set(child.get('class', [])):
            child.decompose()  # advertising
ht_titles(doc)
write('htmanga/home.html', doc)

for name in ('list', 'search'):
    doc = soup(f'ht/{name}.html')
    strip(doc, 'script', 'style', 'link')
    retitle(doc, '紳士漫畫')
    keep_first(doc.select('div.grid div.gallary_wrap > ul.cc > li'), 3)
    ht_titles(doc)
    write(f'htmanga/{name}.html', doc)

doc = soup('ht/info.html')
strip(doc, 'script', 'style', 'link', 'div#comments')
for node in list(doc.find_all(string=lambda t: isinstance(t, Comment))):
    node.extract()
retitle(doc, '样本标题 - 紳士漫畫')
doc.select_one('div.userwrap > h2').string = '样本标题'
bread = doc.select_one('div.png.bread')
bread.contents[-1].replace_with('样本标题')
for i, tag in enumerate(doc.select('a.tagshow'), 1):
    tag.string = f'标签{i}'
    tag['href'] = f'/albums-index-tag-标签{i}.html'
for node in doc.select('div.asTBcell.uwconn > p'):
    if node.get_text().strip():
        node.string = '簡介：样本简介'
info = doc.select_one('div.asTBcell.uwuinfo')
info.select_one('a > p').string = 'uploader1'
for node in info.select(':scope > div'):
    node.string = '簽名：样本签名'
keep_first(doc.select('div.gallary_wrap > ul.cc > li'), 3)
for node in doc.select('div.pic_box.tb > a > img, div.pic_box.tb > a'):
    node.attrs.pop('alt', None)
    node.attrs.pop('title', None)
for node in doc.select('span.name'):
    node.string = '01'
# The "similar galleries" block below the thumbnails is not parsed.
strip(doc, 'div.ar_wrap')
for node in list(doc.find_all(string=lambda t: '相似標籤推薦' in t)):
    node.replace_with('')
write('htmanga/info.html', doc)

lines = (src / 'ht/gallery.js').read_text(encoding='utf-8').splitlines()
kept, images = [], 0
for line in lines:
    if 'url:' in line:
        images += line.count('url:')
        entries = re.findall(r'\{ url: [^}]*\}', line)
        line = line[:line.index('{ url:')] + ','.join(entries[:3]) + '];");' if entries else line
    kept.append(line)
write('htmanga/gallery.js', '\n'.join(kept) + '\n')

# ------------------------------------------------------------------ hitomi

def hitomi_href(href, name):
    # "/tag/female:big breasts-all.html" -> "/tag/female:tag1-all.html"
    kind, rest = href.rsplit('/', 1)
    prefix = re.match(r'(?:female|male)(?::|%3[Aa])', rest)
    return f"{kind}/{prefix.group(0) if prefix else ''}{name}-all.html"


doc = soup('hitomi/block.html')
doc.select_one('h1.lillie > a').string = 'Sample Gallery'
for a in doc.select('a.lillie, h1.lillie > a'):
    a['href'] = '/imageset/sample-gallery-english-4331776.html'
for selector, label in (('div.artist-list a', 'artist'), ('td.series-list a', 'series'),
                        ('td.relatedtags a', 'tag')):
    for i, a in enumerate(doc.select(selector), 1):
        suffix = a.get_text()[-2:] if a.get_text()[-1:] in '♀♂' else ''
        a.string = f'{label}{i}{suffix}'
        a['href'] = hitomi_href(a['href'], f'{label}{i}')
write('hitomi/galleryblock.html', doc)

text = (src / 'hitomi/gallery.js').read_text(encoding='utf-8')
info = json.loads(text[text.index('{'):])
info['files'] = info['files'][:3]
info['title'] = 'Sample Gallery'
info['japanese_title'] = None
info['related'] = info.get('related', [])[:2]
info['languages'] = []
info.pop('scene_indexes', None)
for key, field in (('artists', 'artist'), ('groups', 'group'), ('parodys', 'parody'),
                   ('characters', 'character'), ('tags', 'tag')):
    for i, item in enumerate(info.get(key) or [], 1):
        item[field] = f'{field}{i}'
        item['url'] = hitomi_href(item['url'], f'{field}{i}')
    if info.get(key):
        info[key] = info[key][:4]
write('hitomi/gallery.js', 'var galleryinfo = ' + json.dumps(info, ensure_ascii=False))

text = (src / 'hitomi/gg.js').read_text(encoding='utf-8')
cases = re.findall(r'case \d+:\n', text)
first = text.index(cases[0])
last = text.rindex(cases[-1]) + len(cases[-1])
write('hitomi/gg.js', text[:first] + ''.join(cases[:12]) + text[last:])

# ---------------------------------------------------------------------- jm

def jm_comic(comic, i):
    comic['name'] = f'样本标题{i}'
    comic['author'] = f'作者{i}'
    if 'description' in comic:
        comic['description'] = ''
    return comic


data = json.loads((src / 'jm/promote.json').read_text(encoding='utf-8'))
data = data[:3]
for section in data:
    section['content'] = [jm_comic(c, i) for i, c in enumerate(section['content'][:2], 1)]
write('jm/promote.json', json.dumps(data, ensure_ascii=False, indent=1))

data = json.loads((src / 'jm/search.json').read_text(encoding='utf-8'))
data['content'] = [jm_comic(c, i) for i, c in enumerate(data['content'][:3], 1)]
write('jm/search.json', json.dumps(data, ensure_ascii=False, indent=1))

data = json.loads((src / 'jm/album.json').read_text(encoding='utf-8'))
data['name'] = '样本标题'
data['description'] = ''
if data.get('author'):
    data['author'] = ['作者1']
for key in ('tags', 'works', 'actors'):
    data[key] = [f'{key}{i}' for i, _ in enumerate(data.get(key, [])[:3], 1)]
data['related_list'] = [jm_comic(c, i) for i, c in enumerate(data.get('related_list', [])[:2], 1)]
write('jm/album.json', json.dumps(data, ensure_ascii=False, indent=1))

data = json.loads((src / 'jm/chapter.json').read_text(encoding='utf-8'))
data['name'] = '样本标题'
data['images'] = data['images'][:3]
data['tags'] = 'tags1 tags2'
write('jm/chapter.json', json.dumps(data, ensure_ascii=False, indent=1))
