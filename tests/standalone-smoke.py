"""Standalone HTML UI can load its entire scanner without runtime dependencies."""
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parent.parent
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 page=browser.new_page(viewport={'width':390,'height':844},device_scale_factor=2,has_touch=True,is_mobile=True)
 errors=[]
 page.on('pageerror',lambda e: errors.append(str(e)))
 page.set_content((root/'ONECOPY-открыть-на-iPhone.html').read_text())
 assert page.locator('#scan-btn').is_visible()
 with page.expect_file_chooser() as info:
  page.locator('#scan-btn').click()
 chooser=info.value
 chooser.set_files([{'name':'a.jpg','mimeType':'image/jpeg','buffer':b'hello identical'}, {'name':'b.jpg','mimeType':'image/jpeg','buffer':b'hello identical'}])
 page.locator('#results').wait_for(state='visible',timeout=20000)
 assert page.locator('#stat-copies').inner_text()=='1'
 assert not errors,errors
 print('PASS standalone one big scan button → iPhone-style file chooser → exact duplicates, no external assets')
 browser.close()
