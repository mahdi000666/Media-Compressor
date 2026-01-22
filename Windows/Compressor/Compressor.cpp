#include <windows.h>
#include <shobjidl.h>
#include <gdiplus.h>
#include <vector>
#include <string>
#include <thread>
#include <mutex>
#include <commctrl.h>
#include <algorithm>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
}

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "avformat.lib")
#pragma comment(lib, "avcodec.lib")
#pragma comment(lib, "avutil.lib")
#pragma comment(lib, "swscale.lib")
#pragma comment(lib, "swresample.lib")

constexpr int MAX_FILES = 10;
constexpr int WM_COMPRESS_COMPLETE = WM_USER + 1;

enum class FileType { Image, Video, Gif, Unknown };

struct FileTask {
    std::wstring path;
    std::wstring outputPath;
    FileType type = FileType::Unknown;
    int quality = 75;
    bool done = false;
};

class Compressor {
    HWND hwnd;
    HWND listBox;
    HWND qualitySlider;
    HWND qualityLabel;
    HWND compressBtn;
    HWND progressBar;
    HWND removeBtn;  // New button
    std::vector<FileTask> tasks;
    std::mutex taskMutex;
    ULONG_PTR gdiplusToken;

    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
        Compressor* app = reinterpret_cast<Compressor*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));

        switch (msg) {
        case WM_CREATE:
            app = reinterpret_cast<Compressor*>(reinterpret_cast<CREATESTRUCT*>(lp)->lpCreateParams);
            SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
            app->CreateControls(hwnd);
            return 0;

        case WM_COMMAND:
            if (app) app->HandleCommand(LOWORD(wp));
            return 0;

        case WM_HSCROLL:
            if (app && reinterpret_cast<HWND>(lp) == app->qualitySlider)
                app->UpdateQualityLabel();
            return 0;

        case WM_COMPRESS_COMPLETE:
            if (app) app->OnCompressComplete();
            return 0;

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        }
        return DefWindowProc(hwnd, msg, wp, lp);
    }

    void CreateControls(HWND hwnd) {
        this->hwnd = hwnd;

        CreateWindowW(L"STATIC", L"Files (max 10):", WS_VISIBLE | WS_CHILD,
            10, 10, 120, 20, hwnd, nullptr, nullptr, nullptr);

        listBox = CreateWindowW(L"LISTBOX", nullptr,
            WS_VISIBLE | WS_CHILD | WS_BORDER | WS_VSCROLL | LBS_NOTIFY,
            10, 35, 560, 200, hwnd, reinterpret_cast<HMENU>(1), nullptr, nullptr);

        CreateWindowW(L"BUTTON", L"Add", WS_VISIBLE | WS_CHILD | BS_PUSHBUTTON,
            10, 245, 100, 30, hwnd, reinterpret_cast<HMENU>(2), nullptr, nullptr);

        removeBtn = CreateWindowW(L"BUTTON", L"Remove", WS_VISIBLE | WS_CHILD | BS_PUSHBUTTON,
            120, 245, 120, 30, hwnd, reinterpret_cast<HMENU>(6), nullptr, nullptr);

        CreateWindowW(L"BUTTON", L"Clear", WS_VISIBLE | WS_CHILD | BS_PUSHBUTTON,
            250, 245, 100, 30, hwnd, reinterpret_cast<HMENU>(3), nullptr, nullptr);

        CreateWindowW(L"STATIC", L"Quality:", WS_VISIBLE | WS_CHILD,
            10, 290, 60, 20, hwnd, nullptr, nullptr, nullptr);

        qualitySlider = CreateWindowW(TRACKBAR_CLASS, nullptr,
            WS_VISIBLE | WS_CHILD | TBS_AUTOTICKS,
            80, 285, 300, 30, hwnd, reinterpret_cast<HMENU>(4), nullptr, nullptr);
        SendMessage(qualitySlider, TBM_SETRANGE, TRUE, MAKELONG(1, 100));
        SendMessage(qualitySlider, TBM_SETPOS, TRUE, 75);

        qualityLabel = CreateWindowW(L"STATIC", L"75", WS_VISIBLE | WS_CHILD | SS_RIGHT,
            390, 290, 40, 20, hwnd, nullptr, nullptr, nullptr);

        compressBtn = CreateWindowW(L"BUTTON", L"Compress", WS_VISIBLE | WS_CHILD | BS_PUSHBUTTON,
            10, 325, 120, 35, hwnd, reinterpret_cast<HMENU>(5), nullptr, nullptr);

        progressBar = CreateWindowW(PROGRESS_CLASS, nullptr, WS_VISIBLE | WS_CHILD,
            10, 370, 560, 25, hwnd, nullptr, nullptr, nullptr);
    }

    void HandleCommand(int id) {
        switch (id) {
        case 2: AddFiles(); break;
        case 3: ClearFiles(); break;
        case 5: StartCompression(); break;
        case 6: RemoveSelectedFile(); break;  // New case
        }
    }

    void AddFiles() {
        if (SendMessage(listBox, LB_GETCOUNT, 0, 0) >= MAX_FILES) {
            MessageBoxW(hwnd, L"Maximum 10 files allowed", L"Limit", MB_OK);
            return;
        }

        IFileOpenDialog* pfd;
        if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL,
            IID_IFileOpenDialog, reinterpret_cast<void**>(&pfd)))) {

            COMDLG_FILTERSPEC filters[] = {
                { L"Media Files", L"*.jpg;*.jpeg;*.png;*.webp;*.gif;*.webm;*.mp4" },
                { L"All Files", L"*.*" }
            };
            pfd->SetFileTypes(2, filters);
            pfd->SetOptions(FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST);

            if (SUCCEEDED(pfd->Show(hwnd))) {
                IShellItemArray* psia;
                if (SUCCEEDED(pfd->GetResults(&psia))) {
                    DWORD count;
                    psia->GetCount(&count);

                    for (DWORD i = 0; i < count && SendMessage(listBox, LB_GETCOUNT, 0, 0) < MAX_FILES; ++i) {
                        IShellItem* psi;
                        if (SUCCEEDED(psia->GetItemAt(i, &psi))) {
                            PWSTR path;
                            if (SUCCEEDED(psi->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
                                SendMessageW(listBox, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(path));
                                CoTaskMemFree(path);
                            }
                            psi->Release();
                        }
                    }
                    psia->Release();
                }
            }
            pfd->Release();
        }
    }

    void ClearFiles() {
        SendMessage(listBox, LB_RESETCONTENT, 0, 0);
    }

    void RemoveSelectedFile() {
        int selectedIndex = static_cast<int>(SendMessage(listBox, LB_GETCURSEL, 0, 0));
        if (selectedIndex != LB_ERR) {
            SendMessage(listBox, LB_DELETESTRING, selectedIndex, 0);

            // If there's another item after the removed one, select it
            int count = static_cast<int>(SendMessage(listBox, LB_GETCOUNT, 0, 0));
            if (count > 0) {
                if (selectedIndex >= count) {
                    selectedIndex = count - 1;
                }
                SendMessage(listBox, LB_SETCURSEL, selectedIndex, 0);
            }
        }
        else {
            MessageBoxW(hwnd, L"Please select a file to remove", L"No Selection", MB_OK | MB_ICONINFORMATION);
        }
    }

    void UpdateQualityLabel() {
        const int q = static_cast<int>(SendMessage(qualitySlider, TBM_GETPOS, 0, 0));
        SetWindowTextW(qualityLabel, std::to_wstring(q).c_str());
    }

    static std::wstring ToLower(const std::wstring& str) {
        std::wstring result = str;
        std::transform(result.begin(), result.end(), result.begin(), ::towlower);
        return result;
    }

    FileType GetFileType(const std::wstring& path) const {
        const size_t dotPos = path.find_last_of(L'.');
        if (dotPos == std::wstring::npos)
            return FileType::Unknown;

        const std::wstring ext = ToLower(path.substr(dotPos));

        if (ext == L".jpg" || ext == L".jpeg" || ext == L".png" || ext == L".webp")
            return FileType::Image;
        if (ext == L".gif")
            return FileType::Gif;
        if (ext == L".mp4" || ext == L".webm")
            return FileType::Video;

        return FileType::Unknown;
    }

    void StartCompression() {
        const int count = static_cast<int>(SendMessage(listBox, LB_GETCOUNT, 0, 0));
        if (count == 0) return;

        const int quality = static_cast<int>(SendMessage(qualitySlider, TBM_GETPOS, 0, 0));

        tasks.clear();
        for (int i = 0; i < count; ++i) {
            const int len = static_cast<int>(SendMessage(listBox, LB_GETTEXTLEN, i, 0));
            std::wstring path(len + 1, L'\0');
            SendMessageW(listBox, LB_GETTEXT, i, reinterpret_cast<LPARAM>(path.data()));
            path.resize(len);

            FileTask task;
            task.path = path;
            task.quality = quality;
            task.type = GetFileType(path);

            const size_t dot = path.find_last_of(L'.');
            if (dot != std::wstring::npos) {
                task.outputPath = path.substr(0, dot) + L"_compressed" + path.substr(dot);
            }
            else {
                task.outputPath = path + L"_compressed";
            }

            tasks.push_back(task);
        }

        SendMessage(progressBar, PBM_SETRANGE, 0, MAKELPARAM(0, count));
        SendMessage(progressBar, PBM_SETPOS, 0, 0);
        EnableWindow(compressBtn, FALSE);

        std::thread([this]() {
            for (auto& task : tasks) {
                CompressFile(task);
                {
                    std::lock_guard<std::mutex> lock(taskMutex);
                    task.done = true;
                }
                PostMessage(hwnd, WM_COMPRESS_COMPLETE, 0, 0);
            }
            }).detach();
    }

    void CompressFile(FileTask& task) const {
        switch (task.type) {
        case FileType::Image:
            CompressImage(task);
            break;
        case FileType::Video:
            CompressVideo(task);
            break;
        case FileType::Gif:
            CompressGif(task);
            break;
        default:
            break;
        }
    }

    void CompressImage(const FileTask& task) const {
        Gdiplus::Bitmap* bmp = Gdiplus::Bitmap::FromFile(task.path.c_str());
        if (!bmp || bmp->GetLastStatus() != Gdiplus::Ok) {
            delete bmp;
            return;
        }

        CLSID encoderClsid;
        GetEncoderClsid(L"image/jpeg", &encoderClsid);

        Gdiplus::EncoderParameters params;
        params.Count = 1;
        params.Parameter[0].Guid = Gdiplus::EncoderQuality;
        params.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
        params.Parameter[0].NumberOfValues = 1;
        ULONG quality = task.quality;
        params.Parameter[0].Value = &quality;

        bmp->Save(task.outputPath.c_str(), &encoderClsid, &params);
        delete bmp;
    }

    void CompressGif(const FileTask& task) const {
        // Convert paths to UTF-8
        std::string inputPath = WideToUtf8(task.path);

        // Change output extension to .gif
        std::wstring outputPath = task.outputPath;
        size_t dotPos = outputPath.find_last_of(L'.');
        if (dotPos != std::wstring::npos) {
            outputPath = outputPath.substr(0, dotPos) + L".gif";
        }
        std::string outputPathUtf8 = WideToUtf8(outputPath);

        AVFormatContext* inFmtCtx = nullptr;
        if (avformat_open_input(&inFmtCtx, inputPath.c_str(), nullptr, nullptr) < 0)
            return;

        if (avformat_find_stream_info(inFmtCtx, nullptr) < 0) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        int videoStreamIdx = -1;
        for (unsigned i = 0; i < inFmtCtx->nb_streams; ++i) {
            if (inFmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                videoStreamIdx = i;
                break;
            }
        }

        if (videoStreamIdx == -1) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        AVStream* inStream = inFmtCtx->streams[videoStreamIdx];

        // Setup decoder
        const AVCodec* decoder = avcodec_find_decoder(inStream->codecpar->codec_id);
        if (!decoder) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        AVCodecContext* decCtx = avcodec_alloc_context3(decoder);
        if (!decCtx) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        if (avcodec_parameters_to_context(decCtx, inStream->codecpar) < 0) {
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        if (avcodec_open2(decCtx, decoder, nullptr) < 0) {
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        // Calculate scaled dimensions based on quality
        double scaleFactor = 0.25 + (task.quality / 100.0) * 0.75;
        int outWidth = static_cast<int>(decCtx->width * scaleFactor);
        int outHeight = static_cast<int>(decCtx->height * scaleFactor);

        // Ensure dimensions are even
        outWidth = (outWidth / 2) * 2;
        outHeight = (outHeight / 2) * 2;

        // Minimum dimensions
        if (outWidth < 16) outWidth = 16;
        if (outHeight < 16) outHeight = 16;

        // Setup output
        AVFormatContext* outFmtCtx = nullptr;
        if (avformat_alloc_output_context2(&outFmtCtx, nullptr, "gif", outputPathUtf8.c_str()) < 0) {
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        // Setup encoder
        const AVCodec* encoder = avcodec_find_encoder(AV_CODEC_ID_GIF);
        if (!encoder) {
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        AVStream* outStream = avformat_new_stream(outFmtCtx, nullptr);
        if (!outStream) {
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        AVCodecContext* encCtx = avcodec_alloc_context3(encoder);
        if (!encCtx) {
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        encCtx->width = outWidth;
        encCtx->height = outHeight;
        // Use RGB8 instead of PAL8 - the GIF encoder can handle this
        encCtx->pix_fmt = AV_PIX_FMT_RGB8;

        // Set proper time base from input stream
        AVRational srcFrameRate = av_guess_frame_rate(inFmtCtx, inStream, nullptr);
        if (srcFrameRate.num <= 0 || srcFrameRate.den <= 0) {
            srcFrameRate = av_make_q(25, 1); // Default to 25 fps
        }

        // For GIF, we need to set time_base carefully
        // GIF uses centiseconds (1/100th of a second) for delays
        encCtx->time_base = av_make_q(1, 100);

        // Reduce frame rate for lower quality settings
        int targetFps = static_cast<int>(av_q2d(srcFrameRate));
        if (task.quality < 30 && targetFps > 10) {
            targetFps = 10;
        }
        else if (task.quality < 60 && targetFps > 15) {
            targetFps = 15;
        }
        if (targetFps < 1) targetFps = 1;

        if (outFmtCtx->oformat->flags & AVFMT_GLOBALHEADER)
            encCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

        if (avcodec_open2(encCtx, encoder, nullptr) < 0) {
            avcodec_free_context(&encCtx);
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        if (avcodec_parameters_from_context(outStream->codecpar, encCtx) < 0) {
            avcodec_free_context(&encCtx);
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }
        outStream->time_base = encCtx->time_base;

        if (avio_open(&outFmtCtx->pb, outputPathUtf8.c_str(), AVIO_FLAG_WRITE) < 0) {
            avcodec_free_context(&encCtx);
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        if (avformat_write_header(outFmtCtx, nullptr) < 0) {
            avio_closep(&outFmtCtx->pb);
            avcodec_free_context(&encCtx);
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        // Setup scaler - convert to RGB8 (not PAL8)
        SwsContext* swsCtx = sws_getContext(
            decCtx->width, decCtx->height, decCtx->pix_fmt,
            outWidth, outHeight, AV_PIX_FMT_RGB8,
            SWS_BILINEAR, nullptr, nullptr, nullptr);

        if (!swsCtx) {
            av_write_trailer(outFmtCtx);
            avio_closep(&outFmtCtx->pb);
            avcodec_free_context(&encCtx);
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        AVPacket* pkt = av_packet_alloc();
        AVFrame* frame = av_frame_alloc();
        AVFrame* encFrame = av_frame_alloc();

        encFrame->format = AV_PIX_FMT_RGB8;
        encFrame->width = outWidth;
        encFrame->height = outHeight;
        if (av_frame_get_buffer(encFrame, 32) < 0) {
            sws_freeContext(swsCtx);
            av_frame_free(&frame);
            av_frame_free(&encFrame);
            av_packet_free(&pkt);
            av_write_trailer(outFmtCtx);
            avio_closep(&outFmtCtx->pb);
            avcodec_free_context(&encCtx);
            avformat_free_context(outFmtCtx);
            avcodec_free_context(&decCtx);
            avformat_close_input(&inFmtCtx);
            return;
        }

        int64_t pts = 0;
        int frameCount = 0;
        int inputFrameCount = 0;

        // Calculate frame skip based on input and target fps
        int srcFps = static_cast<int>(av_q2d(srcFrameRate));
        if (srcFps < 1) srcFps = 25;
        int frameSkip = (srcFps > targetFps) ? (srcFps / targetFps) : 1;
        if (frameSkip < 1) frameSkip = 1;

        // Calculate pts increment for proper timing (in centiseconds)
        int ptsIncrement = 100 / targetFps;
        if (ptsIncrement < 1) ptsIncrement = 1;

        while (av_read_frame(inFmtCtx, pkt) >= 0) {
            if (pkt->stream_index == videoStreamIdx) {
                int sendRet = avcodec_send_packet(decCtx, pkt);
                if (sendRet >= 0) {
                    while (avcodec_receive_frame(decCtx, frame) >= 0) {
                        inputFrameCount++;

                        // Skip frames based on quality setting
                        if ((inputFrameCount - 1) % frameSkip != 0)
                            continue;

                        if (av_frame_make_writable(encFrame) < 0)
                            continue;

                        sws_scale(swsCtx, frame->data, frame->linesize, 0, decCtx->height,
                            encFrame->data, encFrame->linesize);

                        encFrame->pts = pts;
                        pts += ptsIncrement;
                        frameCount++;

                        int encSendRet = avcodec_send_frame(encCtx, encFrame);
                        if (encSendRet >= 0) {
                            AVPacket* encPkt = av_packet_alloc();
                            while (avcodec_receive_packet(encCtx, encPkt) >= 0) {
                                encPkt->stream_index = outStream->index;
                                av_interleaved_write_frame(outFmtCtx, encPkt);
                                av_packet_unref(encPkt);
                            }
                            av_packet_free(&encPkt);
                        }
                    }
                }
            }
            av_packet_unref(pkt);
        }

        // Flush decoder
        avcodec_send_packet(decCtx, nullptr);
        while (avcodec_receive_frame(decCtx, frame) >= 0) {
            inputFrameCount++;

            if ((inputFrameCount - 1) % frameSkip != 0)
                continue;

            if (av_frame_make_writable(encFrame) < 0)
                continue;

            sws_scale(swsCtx, frame->data, frame->linesize, 0, decCtx->height,
                encFrame->data, encFrame->linesize);

            encFrame->pts = pts;
            pts += ptsIncrement;
            frameCount++;

            if (avcodec_send_frame(encCtx, encFrame) >= 0) {
                AVPacket* encPkt = av_packet_alloc();
                while (avcodec_receive_packet(encCtx, encPkt) >= 0) {
                    encPkt->stream_index = outStream->index;
                    av_interleaved_write_frame(outFmtCtx, encPkt);
                    av_packet_unref(encPkt);
                }
                av_packet_free(&encPkt);
            }
        }

        // Flush encoder
        avcodec_send_frame(encCtx, nullptr);
        AVPacket* encPkt = av_packet_alloc();
        while (avcodec_receive_packet(encCtx, encPkt) >= 0) {
            encPkt->stream_index = outStream->index;
            av_interleaved_write_frame(outFmtCtx, encPkt);
            av_packet_unref(encPkt);
        }
        av_packet_free(&encPkt);

        av_write_trailer(outFmtCtx);

        // Cleanup
        sws_freeContext(swsCtx);
        av_frame_free(&frame);
        av_frame_free(&encFrame);
        av_packet_free(&pkt);
        avcodec_free_context(&decCtx);
        avcodec_free_context(&encCtx);
        avformat_close_input(&inFmtCtx);
        avio_closep(&outFmtCtx->pb);
        avformat_free_context(outFmtCtx);
    }

    static std::string WideToUtf8(const std::wstring& wide) {
        if (wide.empty()) return std::string();
        int bufSize = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
        std::string result(bufSize, '\0');
        WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, result.data(), bufSize, nullptr, nullptr);
        result.resize(bufSize - 1);
        return result;
    }

    void CompressVideo(const FileTask& task) const {
        std::string inputPath = WideToUtf8(task.path);
        std::string outputPath = WideToUtf8(task.outputPath);

        AVFormatContext* inFmtCtx = nullptr;
        if (avformat_open_input(&inFmtCtx, inputPath.c_str(), nullptr, nullptr) < 0)
            return;

        if (avformat_find_stream_info(inFmtCtx, nullptr) < 0) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        int videoStreamIdx = -1;
        int audioStreamIdx = -1;

        for (unsigned i = 0; i < inFmtCtx->nb_streams; ++i) {
            if (inFmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && videoStreamIdx == -1) {
                videoStreamIdx = i;
            }
            else if (inFmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audioStreamIdx == -1) {
                audioStreamIdx = i;
            }
        }

        if (videoStreamIdx == -1) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        const AVCodec* decoder = avcodec_find_decoder(inFmtCtx->streams[videoStreamIdx]->codecpar->codec_id);
        if (!decoder) {
            avformat_close_input(&inFmtCtx);
            return;
        }

        AVCodecContext* decCtx = avcodec_alloc_context3(decoder);
        avcodec_parameters_to_context(decCtx, inFmtCtx->streams[videoStreamIdx]->codecpar);
        avcodec_open2(decCtx, decoder, nullptr);

        AVCodecContext* audioDecCtx = nullptr;
        if (audioStreamIdx != -1) {
            const AVCodec* audioDecoder = avcodec_find_decoder(inFmtCtx->streams[audioStreamIdx]->codecpar->codec_id);
            if (audioDecoder) {
                audioDecCtx = avcodec_alloc_context3(audioDecoder);
                avcodec_parameters_to_context(audioDecCtx, inFmtCtx->streams[audioStreamIdx]->codecpar);
                avcodec_open2(audioDecCtx, audioDecoder, nullptr);
            }
        }

        AVFormatContext* outFmtCtx = nullptr;
        avformat_alloc_output_context2(&outFmtCtx, nullptr, nullptr, outputPath.c_str());

        const AVCodec* encoder = avcodec_find_encoder(AV_CODEC_ID_H264);
        AVStream* outVideoStream = avformat_new_stream(outFmtCtx, nullptr);
        AVCodecContext* encCtx = avcodec_alloc_context3(encoder);

        encCtx->width = decCtx->width;
        encCtx->height = decCtx->height;
        encCtx->time_base = av_inv_q(av_guess_frame_rate(inFmtCtx, inFmtCtx->streams[videoStreamIdx], nullptr));
        encCtx->pix_fmt = AV_PIX_FMT_YUV420P;
        encCtx->bit_rate = decCtx->bit_rate > 0 ? (int64_t)(decCtx->bit_rate * (task.quality / 100.0)) : 2000000;

        if (outFmtCtx->oformat->flags & AVFMT_GLOBALHEADER)
            encCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

        avcodec_open2(encCtx, encoder, nullptr);
        avcodec_parameters_from_context(outVideoStream->codecpar, encCtx);
        outVideoStream->time_base = encCtx->time_base;

        AVCodecContext* audioEncCtx = nullptr;
        AVStream* outAudioStream = nullptr;
        if (audioDecCtx) {
            const AVCodec* audioEncoder = avcodec_find_encoder(AV_CODEC_ID_AAC);
            if (audioEncoder) {
                outAudioStream = avformat_new_stream(outFmtCtx, nullptr);
                audioEncCtx = avcodec_alloc_context3(audioEncoder);
                audioEncCtx->sample_rate = audioDecCtx->sample_rate;

                const enum AVSampleFormat* formats = nullptr;

                if (avcodec_get_supported_config(nullptr, audioEncoder, AV_CODEC_CONFIG_SAMPLE_FORMAT,
                    0, (const void**)&formats, nullptr) >= 0 && formats) {
                    audioEncCtx->sample_fmt = formats[0];
                }
                else {
                    audioEncCtx->sample_fmt = AV_SAMPLE_FMT_FLTP;
                }

                audioEncCtx->ch_layout = audioDecCtx->ch_layout;
                audioEncCtx->bit_rate = 128000;
                audioEncCtx->time_base = { 1, audioDecCtx->sample_rate };

                if (outFmtCtx->oformat->flags & AVFMT_GLOBALHEADER)
                    audioEncCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

                avcodec_open2(audioEncCtx, audioEncoder, nullptr);
                avcodec_parameters_from_context(outAudioStream->codecpar, audioEncCtx);
                outAudioStream->time_base = audioEncCtx->time_base;
            }
        }

        avio_open(&outFmtCtx->pb, outputPath.c_str(), AVIO_FLAG_WRITE);
        avformat_write_header(outFmtCtx, nullptr);

        AVPacket* pkt = av_packet_alloc();
        AVFrame* frame = av_frame_alloc();
        AVFrame* encFrame = av_frame_alloc();
        encFrame->format = encCtx->pix_fmt;
        encFrame->width = encCtx->width;
        encFrame->height = encCtx->height;
        av_frame_get_buffer(encFrame, 0);

        SwsContext* swsCtx = nullptr;
        if (decCtx->pix_fmt != encCtx->pix_fmt) {
            swsCtx = sws_getContext(decCtx->width, decCtx->height, decCtx->pix_fmt,
                encCtx->width, encCtx->height, encCtx->pix_fmt, SWS_BILINEAR, nullptr, nullptr, nullptr);
        }

        int64_t videoPts = 0;
        int64_t audioPts = 0;

        while (av_read_frame(inFmtCtx, pkt) >= 0) {
            if (pkt->stream_index == videoStreamIdx) {
                avcodec_send_packet(decCtx, pkt);

                while (avcodec_receive_frame(decCtx, frame) == 0) {
                    av_frame_make_writable(encFrame);
                    if (swsCtx) {
                        sws_scale(swsCtx, frame->data, frame->linesize, 0, decCtx->height,
                            encFrame->data, encFrame->linesize);
                        encFrame->pts = videoPts++;
                    }
                    else {
                        av_frame_copy(encFrame, frame);
                        encFrame->pts = videoPts++;
                    }

                    avcodec_send_frame(encCtx, encFrame);

                    AVPacket* encPkt = av_packet_alloc();
                    while (avcodec_receive_packet(encCtx, encPkt) == 0) {
                        av_packet_rescale_ts(encPkt, encCtx->time_base, outVideoStream->time_base);
                        encPkt->stream_index = outVideoStream->index;
                        av_interleaved_write_frame(outFmtCtx, encPkt);
                    }
                    av_packet_free(&encPkt);
                }
            }
            else if (pkt->stream_index == audioStreamIdx && audioEncCtx) {
                avcodec_send_packet(audioDecCtx, pkt);

                while (avcodec_receive_frame(audioDecCtx, frame) == 0) {
                    frame->pts = audioPts;
                    audioPts += frame->nb_samples;

                    avcodec_send_frame(audioEncCtx, frame);

                    AVPacket* encPkt = av_packet_alloc();
                    while (avcodec_receive_packet(audioEncCtx, encPkt) == 0) {
                        av_packet_rescale_ts(encPkt, audioEncCtx->time_base, outAudioStream->time_base);
                        encPkt->stream_index = outAudioStream->index;
                        av_interleaved_write_frame(outFmtCtx, encPkt);
                    }
                    av_packet_free(&encPkt);
                }
            }
            av_packet_unref(pkt);
        }

        avcodec_send_frame(encCtx, nullptr);
        AVPacket* encPkt = av_packet_alloc();
        while (avcodec_receive_packet(encCtx, encPkt) == 0) {
            av_packet_rescale_ts(encPkt, encCtx->time_base, outVideoStream->time_base);
            encPkt->stream_index = outVideoStream->index;
            av_interleaved_write_frame(outFmtCtx, encPkt);
        }
        av_packet_free(&encPkt);

        if (audioEncCtx) {
            avcodec_send_frame(audioEncCtx, nullptr);
            AVPacket* audioEncPkt = av_packet_alloc();
            while (avcodec_receive_packet(audioEncCtx, audioEncPkt) == 0) {
                av_packet_rescale_ts(audioEncPkt, audioEncCtx->time_base, outAudioStream->time_base);
                audioEncPkt->stream_index = outAudioStream->index;
                av_interleaved_write_frame(outFmtCtx, audioEncPkt);
            }
            av_packet_free(&audioEncPkt);
        }

        av_write_trailer(outFmtCtx);

        if (swsCtx) sws_freeContext(swsCtx);
        av_frame_free(&frame);
        av_frame_free(&encFrame);
        av_packet_free(&pkt);
        avcodec_free_context(&decCtx);
        if (audioDecCtx) avcodec_free_context(&audioDecCtx);
        avcodec_free_context(&encCtx);
        if (audioEncCtx) avcodec_free_context(&audioEncCtx);
        avformat_close_input(&inFmtCtx);
        avio_closep(&outFmtCtx->pb);
        avformat_free_context(outFmtCtx);
    }

    bool GetEncoderClsid(const WCHAR* format, CLSID* pClsid) const {
        UINT num = 0, size = 0;
        Gdiplus::GetImageEncodersSize(&num, &size);
        if (size == 0) return false;

        auto* pImageCodecInfo = static_cast<Gdiplus::ImageCodecInfo*>(malloc(size));
        if (!pImageCodecInfo) return false;

        Gdiplus::GetImageEncoders(num, size, pImageCodecInfo);

        for (UINT i = 0; i < num; ++i) {
            if (wcscmp(pImageCodecInfo[i].MimeType, format) == 0) {
                *pClsid = pImageCodecInfo[i].Clsid;
                free(pImageCodecInfo);
                return true;
            }
        }
        free(pImageCodecInfo);
        return false;
    }

    void OnCompressComplete() {
        int done = 0;
        {
            std::lock_guard<std::mutex> lock(taskMutex);
            for (const auto& task : tasks)
                if (task.done) ++done;
        }

        SendMessage(progressBar, PBM_SETPOS, done, 0);

        if (done == static_cast<int>(tasks.size())) {
            EnableWindow(compressBtn, TRUE);
            MessageBoxW(hwnd, L"Compression complete!", L"Done", MB_OK);
        }
    }

public:
    Compressor() : hwnd(nullptr), listBox(nullptr), qualitySlider(nullptr),
        qualityLabel(nullptr), compressBtn(nullptr), progressBar(nullptr),
        removeBtn(nullptr), gdiplusToken(0) {
        Gdiplus::GdiplusStartupInput gdiplusStartupInput;
        Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, nullptr);
    }

    ~Compressor() {
        Gdiplus::GdiplusShutdown(gdiplusToken);
    }

    int Run(HINSTANCE hInst) {
        WNDCLASSW wc = {};
        wc.lpfnWndProc = WndProc;
        wc.hInstance = hInst;
        wc.lpszClassName = L"CompressorClass";
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);

        RegisterClassW(&wc);

        const HWND hwnd = CreateWindowW(L"CompressorClass", L"Compressor",
            WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
            CW_USEDEFAULT, CW_USEDEFAULT, 600, 450,
            nullptr, nullptr, hInst, this);

        ShowWindow(hwnd, SW_SHOW);

        MSG msg;
        while (GetMessage(&msg, nullptr, 0, 0)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }

        return static_cast<int>(msg.wParam);
    }
};

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int) {
    CoInitialize(nullptr);
    InitCommonControls();

    Compressor app;
    const int ret = app.Run(hInst);

    CoUninitialize();
    return ret;
}