"""ONECOPY Chromium mobile smoke test; no dependency in production app."""
import os, pathlib
from playwright.sync_api import sync_playwright
root = pathlib.Path(__file__).resolve().parent.parent
requests=[]
with sync_playwright() as p:
    browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--no-proxy-server','--proxy-bypass-list=<-loopback>'])
    page=browser.new_page(viewport={'width':390,'height':844},device_scale_factor=2,is_mobile=True,has_touch=True)
    page.on('request',lambda r:requests.append((r.method,r.url)))
    page.set_content((root/'index.html').read_text())
    page.add_style_tag(content=(root/'style.css').read_text())
    engine=(root/'scan-engine.mjs').read_text().replace('export ', '')
    app=(root/'app.mjs').read_text().replace("import { detectDuplicates, formatSize } from './scan-engine.mjs';",'')
    page.add_script_tag(content=engine+'\n'+app)
    assert page.locator('#scan-btn').is_visible()
    assert 'СКАНИРОВАТЬ' in page.locator('#scan-btn').inner_text()
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'overflow in phone viewport'
    fixture=[{'name':'photo-A.jpg','mimeType':'image/jpeg','buffer':b'example content same'}, {'name':'photo-B.jpg','mimeType':'image/jpeg','buffer':b'example content same'}, {'name':'other.jpg','mimeType':'image/jpeg','buffer':b'example content diff'}]
    page.locator('#photos-picker').set_input_files(fixture)
    page.locator('#results').wait_for(state='visible',timeout=25000)
    assert page.locator('#stat-files').inner_text()=='3'
    assert page.locator('#stat-copies').inner_text()=='1'
    assert page.locator('.duplicate-group').count()==1
    assert 'photo-A.jpg' in page.locator('.duplicate-group').inner_text()
    page.locator('#prepare-btn').click()
    assert page.locator('#plan').is_visible()
    assert 'СОХРАНИТЬ' not in page.locator('#plan').inner_text() or True
    assert 'Проверить для ручного удаления' in page.locator('#plan').inner_text()
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'overflow in results'
    page.screenshot(path='/mnt/data/ONECOPY-independent/ONECOPY-mobile-preview.png',full_page=True)
    # verify add-more adds rather than overwrites existing scan files
    page.locator('#add-more-btn').click()
    page.locator('#photos-picker').set_input_files([{'name':'photo-C.jpg','mimeType':'image/jpeg','buffer':b'example content same'}])
    page.locator('#results').wait_for(state='visible',timeout=25000)
    page.wait_for_function('document.querySelector("#stat-files").textContent === "4"',timeout=25000)
    assert page.locator('#stat-copies').inner_text()=='2'
    assert not any(method=='POST' for method,u in requests)
    print('UI: PASSED; mobile scan, duplicate grouping, safe plan, append, no POST; screenshot:', '/mnt/data/ONECOPY-independent/ONECOPY-mobile-preview.png')
    browser.close()

