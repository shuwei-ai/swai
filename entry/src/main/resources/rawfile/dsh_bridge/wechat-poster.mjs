/**
 * WeChat Official Account (微信公众号) Poster Engine via CDP
 * Operates in-app ArkWeb browser at 127.0.0.1:9222.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import { formatMarkdownToWechat } from './wechat-formatter.mjs';

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export class WeChatPoster {
  constructor(cdpDriver) {
    this.cdp = cdpDriver;
  }

  /**
   * Check current login state of WeChat Official Account in ArkWeb
   */
  async checkLoginState() {
    await this.cdp.ensureConnected();

    // Check current page URL
    let currentUrl = '';
    try {
      currentUrl = await this.cdp.evaluate('window.location.href');
    } catch {}

    if (!currentUrl || !currentUrl.includes('mp.weixin.qq.com')) {
      // Navigate to WeChat Official Account login page
      await this.cdp.send('Page.navigate', { url: 'https://mp.weixin.qq.com/' });
      await sleep(2500);
    }

    const checkResult = await this.cdp.evaluate(`
      (function() {
        const url = window.location.href;
        const text = document.body ? document.body.innerText : '';
        const hasHomeToken = url.includes('/cgi-bin/home') || (url.includes('/cgi-bin/') && url.includes('token='));
        const isLoginPrompt = text.includes('扫码登录') || text.includes('使用账号登录') || text.includes('请重新登录');

        if (hasHomeToken && !isLoginPrompt) {
          const match = url.match(/token=([^&]+)/);
          return {
            status: 'logged_in',
            token: match ? match[1] : '',
            url: url
          };
        }

        return {
          status: 'need_login',
          url: url,
          message: '微信公众平台尚未登录。请在屏幕右侧浏览器中扫码登录微信公众号账号。'
        };
      })()
    `);

    return checkResult;
  }

  /**
   * Navigate or switch to article draft editor
   */
  async openEditor(token) {
    await this.cdp.ensureConnected();

    const currentUrl = await this.cdp.evaluate('window.location.href');
    if (currentUrl.includes('appmsg_edit') || currentUrl.includes('appmsg-edit')) {
      // Already in editor page
      return true;
    }

    // Direct navigation using token
    let editUrl = '';
    if (token) {
      editUrl = `https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit&action=edit&type=77&isNew=1&lang=zh_CN&token=${token}`;
    } else {
      // Extract from page
      const extractedToken = await this.cdp.evaluate(`
        (function() {
          const match = window.location.href.match(/token=([^&]+)/);
          return match ? match[1] : (window.cgiData && window.cgiData.token) || '';
        })()
      `);
      if (extractedToken) {
        editUrl = `https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit&action=edit&type=77&isNew=1&lang=zh_CN&token=${extractedToken}`;
      }
    }

    if (editUrl) {
      console.log(`[wechat-poster] Navigating to editor URL: ${editUrl}`);
      await this.cdp.send('Page.navigate', { url: editUrl });
      await sleep(3500);
      return true;
    }

    // Fallback: try clicking new article menu button on home page
    const clicked = await this.cdp.evaluate(`
      (function() {
        const items = document.querySelectorAll('.new-creation__menu .new-creation__menu-item');
        for (const item of items) {
          const title = item.querySelector('.new-creation__menu-title');
          if (title && (title.textContent.trim() === '文章' || title.textContent.trim() === '图文')) {
            item.click();
            return true;
          }
        }
        return false;
      })()
    `);

    if (clicked) {
      await sleep(3000);
      return true;
    }

    throw new Error('无法进入微信文章编辑器，请确认是否已成功登录公众号后台。');
  }

  /**
   * Wait until editor elements are ready in DOM
   */
  async waitForEditorReady(timeoutMs = 20000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const ready = await this.cdp.evaluate(`
        (function() {
          const title = document.querySelector('#title');
          const editor = document.querySelector('.rich_media_content .ProseMirror') ||
                        document.querySelector('#js_editor [contenteditable=\"true\"]') ||
                        document.querySelector('.edui-body-container');
          return Boolean(title && editor);
        })()
      `).catch(() => false);

      if (ready) return true;
      await sleep(500);
    }
    throw new Error('等待文章编辑器加载超时，请检查网络或刷新页面');
  }

  /**
   * Inject formatted article into WeChat editor
   */
  async fillArticle(article) {
    const { title, author, summary, html } = article;

    // 1. Inject HTML into editor body
    const bodyResult = await this.cdp.evaluate(`
      (function(htmlContent) {
        const editor = document.querySelector('.rich_media_content .ProseMirror') ||
                      document.querySelector('#js_editor [contenteditable=\"true\"]') ||
                      document.querySelector('.edui-body-container');
        if (!editor) return { ok: false, error: 'Editor container not found' };

        const template = document.createElement('template');
        template.innerHTML = htmlContent;
        const output = template.content.querySelector('#output') || template.content;

        editor.focus();
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(editor);
        range.deleteContents();
        range.collapse(true);
        selection.removeAllRanges();
        selection.addRange(range);

        // Execute insertHTML
        const inserted = document.execCommand('insertHTML', false, output.innerHTML || htmlContent);

        // Dispatch input event to notify ProseMirror / Vue reactively
        editor.dispatchEvent(new InputEvent('input', {
          bubbles: true,
          inputType: 'insertHTML',
          data: editor.innerText || ''
        }));

        return {
          ok: Boolean(inserted || (editor.innerText || '').trim().length > 0),
          length: (editor.innerText || '').trim().length
        };
      })(${JSON.stringify(html)})
    `);

    if (!bodyResult.ok) {
      throw new Error(`正文注入失败: ${bodyResult.error || '未能成功写入编辑器'}`);
    }

    // 2. Set Title
    if (title) {
      await this.cdp.evaluate(`
        (function(text) {
          const el = document.querySelector('#title');
          if (el) {
            el.value = text;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
        })(${JSON.stringify(title)})
      `);
    }

    // 3. Set Author
    if (author) {
      await this.cdp.evaluate(`
        (function(text) {
          const el = document.querySelector('#author');
          if (el) {
            el.value = text;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
        })(${JSON.stringify(author)})
      `);
    }

    // 4. Set Summary / Description
    if (summary) {
      await this.cdp.evaluate(`
        (function(text) {
          const el = document.querySelector('#js_description');
          if (el) {
            el.value = text;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
        })(${JSON.stringify(summary)})
      `);
    }

    return true;
  }

  /**
   * Click save draft button and wait for completion
   */
  async saveDraft(timeoutMs = 25000) {
    const saveTriggered = await this.cdp.evaluate(`
      (function() {
        // 1. 关闭阻挡点击的弹窗
        const closeBtn = Array.from(document.querySelectorAll('.weui-desktop-dialog button, .weui-desktop-dialog a, .weui-desktop-icon-btn_close'))
          .find(b => (b.innerText || '').trim() === '关闭' || (b.innerText || '').trim() === '取消');
        if (closeBtn) {
          try { closeBtn.click(); } catch(e) {}
        }

        // 2. 优先命中确定的精确选择器: #js_submit > button > span
        let targetEl = document.querySelector('#js_submit > button > span');
        if (!targetEl) {
          targetEl = document.querySelector('#js_submit button') ||
                     document.querySelector('button#js_submit') ||
                     document.querySelector('#js_submit') ||
                     document.querySelector('.js_save_draft') ||
                     document.querySelector('.btn_save_draft');
        }
        if (!targetEl) {
          // 模糊文本匹配
          targetEl = Array.from(document.querySelectorAll('button, a, span, div[role="button"]')).find(function(el) {
            const text = (el.innerText || el.textContent || '').trim();
            return (text === '保存为草稿' || text === '保存草稿' || text === '保存') &&
                   !text.includes('群发') && !text.includes('发表') && !text.includes('发布');
          });
        }

        if (targetEl) {
          try { targetEl.scrollIntoView({ block: 'center' }); } catch(e) {}

          const buttonParent = targetEl.closest('button') || targetEl.parentElement;

          function triggerClick(el) {
            if (!el) return;
            const rect = el.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;
            const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y };
            try { el.dispatchEvent(new MouseEvent('mousedown', opts)); } catch(e) {}
            try { el.dispatchEvent(new MouseEvent('mouseup', opts)); } catch(e) {}
            try { el.dispatchEvent(new MouseEvent('click', opts)); } catch(e) {}
            if (typeof el.click === 'function') {
              try { el.click(); } catch(e) {}
            }
          }

          // 触发 target 自身 (span) 与外层 button
          triggerClick(targetEl);
          if (buttonParent && buttonParent !== targetEl) {
            triggerClick(buttonParent);
          }

          return {
            ok: true,
            text: (targetEl.innerText || targetEl.textContent || buttonParent?.innerText || '').trim()
          };
        }

        return { ok: false, error: 'Save draft button not found' };
      })()
    `);

    if (!saveTriggered.ok) {
      throw new Error(`保存草稿按钮点击失败: ${saveTriggered.error}`);
    }

    // Poll for save result
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const status = await this.cdp.evaluate(`
        (function() {
          const url = location.href;
          const appmsgid = new URL(url).searchParams.get('appmsgid') || (window.appmsgid || '');
          const toastList = Array.from(document.querySelectorAll('.weui-desktop-toast, .weui-desktop-toptips, .js_tips, [class*=toast], .weui-toast'))
            .map(el => (el.innerText || '').trim())
            .filter(Boolean);

          const successToast = toastList.find(t => /已保存|保存成功|已保存草稿/i.test(t));
          const failToast = toastList.find(t => /保存失败|错误/i.test(t));

          if (successToast || (appmsgid && !document.querySelector('#js_submit.btn_loading'))) {
            return { done: true, ok: true, appmsgid: String(appmsgid), msg: successToast || '已保存草稿' };
          }
          if (failToast) {
            return { done: true, ok: false, msg: failToast };
          }
          return { done: false };
        })()
      `).catch(() => ({ done: false }));

      if (status.done) {
        if (!status.ok) {
          throw new Error(`保存草稿失败: ${status.msg}`);
        }
        return status;
      }
      await sleep(1000);
    }

    return { done: true, ok: true, appmsgid: '', msg: '保存请求已发出（等待超时，可在公众号后台查看）' };
  }

  /**
   * Main entry: Publish markdown content to WeChat draft
   */
  async publishMarkdown(markdownContent, options = {}) {
    // 1. Format Markdown to WeChat inline HTML
    console.log('[wechat-poster] Formatting Markdown with baoyu-md...');
    const formatted = await formatMarkdownToWechat(markdownContent, {
      title: options.title,
      author: options.author,
      summary: options.summary,
      theme: options.theme || 'default',
      color: options.color,
      citeStatus: options.citeStatus !== false,
    });

    console.log(`[wechat-poster] Formatted: title="${formatted.title}", htmlLength=${formatted.html.length}`);

    // 2. Check login state
    console.log('[wechat-poster] Checking WeChat login state...');
    const loginInfo = await this.checkLoginState();
    if (loginInfo.status !== 'logged_in') {
      return {
        success: false,
        status: 'need_login',
        message: '微信公众平台尚未登录。已为你打开浏览器，请在真机屏幕右侧扫码登录微信公众号后台后再次重试。',
        title: formatted.title,
        summary: formatted.summary,
      };
    }

    // 3. Open editor
    console.log('[wechat-poster] Opening WeChat article editor...');
    await this.openEditor(loginInfo.token);

    // 4. Wait for editor ready
    console.log('[wechat-poster] Waiting for editor DOM ready...');
    await this.waitForEditorReady();

    // 5. Fill title, author, summary and inject formatted HTML
    console.log('[wechat-poster] Injecting article content...');
    await this.fillArticle(formatted);

    // 6. Save Draft if required
    let saveResult = { ok: true, msg: '内容已填充到编辑器' };
    if (options.saveDraft !== false) {
      console.log('[wechat-poster] Saving draft...');
      saveResult = await this.saveDraft();
    }

    return {
      success: true,
      status: 'success',
      title: formatted.title,
      author: formatted.author,
      summary: formatted.summary,
      saveResult: saveResult.msg,
      appmsgid: saveResult.appmsgid || undefined
    };
  }
}
