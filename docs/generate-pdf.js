const puppeteer = require('puppeteer');
const path = require('path');

(async () => {
  const browser = await puppeteer.launch();
  const page = await browser.newPage();

  const filePath = path.resolve(__dirname, 'technical-reference.html');
  await page.goto(`file://${filePath}`, { waitUntil: 'networkidle2' });

  // Wait for web fonts to render
  await page.evaluateHandle('document.fonts.ready');

  await page.pdf({
    path: path.resolve(__dirname, 'technical-reference.pdf'),
    format: 'A4',
    printBackground: true,
    margin: { top: '16mm', right: '16mm', bottom: '16mm', left: '16mm' },
  });

  await browser.close();
  console.log('Done: docs/technical-reference.pdf');
})();
