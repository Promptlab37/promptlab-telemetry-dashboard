package cz.promptlab.telemetry;

import android.os.Handler;
import android.os.Looper;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * Znovu nacita stranku, dokud server na pocitaci nezacne odpovidat.
 *
 * Duvod: aplikaci spoustime hned po prihlaseni, jeste nez nabehne
 * server.ps1. Bez teto logiky by WebView zobrazil chybovou stranku
 * prohlizece a uz by se sam nezotavil.
 *
 * Pozn.: samostatna pojmenovana trida zamerne - d8 pri kompilaci
 * s -source 8 padal na anonymnich vnitrnich tridach.
 */
public class RetryClient extends WebViewClient implements Runnable {

    private final WebView web;
    private final String url;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private int tries = 0;

    public RetryClient(WebView w, String u) {
        web = w;
        url = u;
    }

    /** Novejsi Android */
    @Override
    public void onReceivedError(WebView view, WebResourceRequest req, WebResourceError err) {
        if (req != null && !req.isForMainFrame()) return;
        schedule();
    }

    /** Starsi Android */
    @Override
    public void onReceivedError(WebView view, int code, String desc, String failingUrl) {
        schedule();
    }

    private void schedule() {
        tries++;
        // Prvni pokusy husto (server nabiha), pak uz v klidu.
        long delay = (tries <= 25) ? 600 : 3000;
        ui.removeCallbacks(this);
        ui.postDelayed(this, delay);
    }

    @Override
    public void run() {
        if (web != null) web.loadUrl(url);
    }

    @Override
    public void onPageFinished(WebView view, String u) {
        tries = 0;
    }
}
