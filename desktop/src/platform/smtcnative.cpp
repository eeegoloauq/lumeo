#include "smtcnative.h"

#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <windows.media.h>
#include <winstring.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <optional>
#include <utility>

namespace {
namespace Foundation = ABI::Windows::Foundation;
namespace Media = ABI::Windows::Media;
namespace Streams = ABI::Windows::Storage::Streams;
using Microsoft::WRL::ComPtr;
using Button = SmtcNative::Button;
constexpr double ticksPerSecond = 10000000;

class HString {
public:
  explicit HString(std::wstring_view text) {
    WindowsCreateString(text.data(), static_cast<UINT32>(text.size()), &m_value);
  }
  ~HString() { WindowsDeleteString(m_value); }
  HSTRING get() const { return m_value; }

private:
  HSTRING m_value = nullptr;
};

template <typename Interface> HRESULT factory(std::wstring_view name, ComPtr<Interface> &out) {
  return RoGetActivationFactory(HString(name).get(), IID_PPV_ARGS(out.ReleaseAndGetAddressOf()));
}

template <typename RuntimeArgs, typename InterfaceArgs, typename Function>
class EventHandler final
    : public Foundation::ITypedEventHandler<Media::SystemMediaTransportControls *, RuntimeArgs *> {
  using Interface = Foundation::ITypedEventHandler<Media::SystemMediaTransportControls *, RuntimeArgs *>;

public:
  explicit EventHandler(Function callback) : m_callback(std::move(callback)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
    if (!out)
      return E_POINTER;
    *out = nullptr;
    if (id != __uuidof(Interface) && id != __uuidof(IUnknown) && id != __uuidof(IAgileObject))
      return E_NOINTERFACE;
    *out = static_cast<Interface *>(this);
    AddRef();
    return S_OK;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++m_refs; }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG left = --m_refs;
    if (!left)
      delete this;
    return left;
  }

  HRESULT STDMETHODCALLTYPE Invoke(Media::ISystemMediaTransportControls *, InterfaceArgs *args) override {
    if (args)
      m_callback(args);
    return S_OK;
  }

private:
  std::atomic<ULONG> m_refs{1};
  Function m_callback;
};

template <typename RuntimeArgs, typename InterfaceArgs, typename Function>
auto makeHandler(Function callback) {
  using Interface = Foundation::ITypedEventHandler<Media::SystemMediaTransportControls *, RuntimeArgs *>;
  ComPtr<Interface> handler;
  handler.Attach(new EventHandler<RuntimeArgs, InterfaceArgs, Function>(std::move(callback)));
  return handler;
}

std::optional<Button> translate(Media::SystemMediaTransportControlsButton button) {
  switch (button) {
  case Media::SystemMediaTransportControlsButton_Play: return Button::Play;
  case Media::SystemMediaTransportControlsButton_Pause: return Button::Pause;
  case Media::SystemMediaTransportControlsButton_Stop: return Button::Stop;
  case Media::SystemMediaTransportControlsButton_Next: return Button::Next;
  case Media::SystemMediaTransportControlsButton_Previous: return Button::Previous;
  default: return std::nullopt;
  }
}

ComPtr<Streams::IRandomAccessStreamReference> thumbnail(std::wstring_view address) {
  ComPtr<Streams::IRandomAccessStreamReference> result;
  if (address.empty())
    return result;
  ComPtr<Foundation::IUriRuntimeClassFactory> uriFactory;
  ComPtr<Foundation::IUriRuntimeClass> uri;
  ComPtr<Streams::IRandomAccessStreamReferenceStatics> streams;
  if (SUCCEEDED(factory(L"Windows.Foundation.Uri", uriFactory)) &&
      SUCCEEDED(uriFactory->CreateUri(HString(address).get(), uri.GetAddressOf())) &&
      SUCCEEDED(factory(L"Windows.Storage.Streams.RandomAccessStreamReference", streams)))
    streams->CreateFromUri(uri.Get(), result.GetAddressOf());
  return result;
}

Foundation::TimeSpan timeSpan(double seconds) {
  constexpr auto limit = std::numeric_limits<INT64>::max() / static_cast<INT64>(ticksPerSecond);
  return {static_cast<INT64>(std::clamp(seconds, 0.0, static_cast<double>(limit)) * ticksPerSecond)};
}
} // namespace

struct SmtcNative::State {
  void clear() {
    if (controls) {
      controls->put_IsEnabled(false);
      controls->put_PlaybackStatus(Media::MediaPlaybackStatus_Closed);
    }
    if (display) {
      display->ClearAll();
      display->Update();
    }
  }

  ~State() {
    if (buttonToken)
      controls->remove_ButtonPressed(*buttonToken);
    if (seekToken)
      timeline->remove_PlaybackPositionChangeRequested(*seekToken);
    clear();
    properties.Reset();
    seekHandler.Reset();
    timeline.Reset();
    display.Reset();
    controls.Reset();
    if (initialized)
      RoUninitialize();
  }

  bool initialized = false;
  HRESULT error = E_FAIL;
  ComPtr<Media::ISystemMediaTransportControls> controls;
  ComPtr<Media::ISystemMediaTransportControlsDisplayUpdater> display;
  ComPtr<Media::ISystemMediaTransportControls2> timeline;
  ComPtr<Media::ISystemMediaTransportControlsTimelineProperties> properties;
  ComPtr<Foundation::ITypedEventHandler<Media::SystemMediaTransportControls *,
                                        Media::PlaybackPositionChangeRequestedEventArgs *>> seekHandler;
  std::optional<EventRegistrationToken> buttonToken;
  std::optional<EventRegistrationToken> seekToken;
};

SmtcNative::SmtcNative(void *window, ButtonHandler button, SeekHandler seek)
    : m_state(std::make_unique<State>()) {
  auto &state = *m_state;
  state.error = RoInitialize(RO_INIT_SINGLETHREADED);
  if (FAILED(state.error))
    return;
  state.initialized = true;
  ComPtr<ISystemMediaTransportControlsInterop> interop;
  state.error = factory(L"Windows.Media.SystemMediaTransportControls", interop);
  if (FAILED(state.error))
    return;
  state.error = interop->GetForWindow(static_cast<HWND>(window),
                                      IID_PPV_ARGS(state.controls.GetAddressOf()));
  if (FAILED(state.error))
    return;
  state.error = state.controls->get_DisplayUpdater(state.display.GetAddressOf());
  if (FAILED(state.error))
    return;

  auto handler = makeHandler<Media::SystemMediaTransportControlsButtonPressedEventArgs,
                             Media::ISystemMediaTransportControlsButtonPressedEventArgs>(
      [callback = std::move(button)](auto *args) {
        Media::SystemMediaTransportControlsButton key{};
        if (SUCCEEDED(args->get_Button(&key)))
          if (const auto action = translate(key))
            callback(*action);
      });
  EventRegistrationToken token{};
  state.error = state.controls->add_ButtonPressed(handler.Get(), &token);
  if (FAILED(state.error))
    return;
  state.buttonToken = token;

  if (SUCCEEDED(state.controls.As(&state.timeline))) {
    state.seekHandler = makeHandler<Media::PlaybackPositionChangeRequestedEventArgs,
                                    Media::IPlaybackPositionChangeRequestedEventArgs>(
        [callback = std::move(seek)](auto *args) {
          Foundation::TimeSpan position{};
          if (SUCCEEDED(args->get_RequestedPlaybackPosition(&position)))
            callback(position.Duration / ticksPerSecond);
        });
  }
  state.controls->put_IsPlayEnabled(true);
  state.controls->put_IsPauseEnabled(true);
  state.controls->put_IsStopEnabled(true);
}

bool SmtcNative::ready() const {
  return SUCCEEDED(m_state->error);
}

long SmtcNative::error() const {
  return m_state->error;
}

SmtcNative::~SmtcNative() = default;

bool SmtcNative::enable() {
  m_state->error = m_state->controls->put_IsEnabled(true);
  return ready();
}

void SmtcNative::setPlayback(bool paused, bool canNext, bool canPrevious) {
  auto &controls = m_state->controls;
  controls->put_PlaybackStatus(paused ? Media::MediaPlaybackStatus_Paused
                                      : Media::MediaPlaybackStatus_Playing);
  controls->put_IsNextEnabled(canNext);
  controls->put_IsPreviousEnabled(canPrevious);
}

void SmtcNative::setMetadata(std::wstring_view title, std::wstring_view series,
                            std::wstring_view poster) {
  auto &display = m_state->display;
  display->ClearAll();
  // MinGW declares the music display interface, which exposes both title and series.
  display->put_Type(Media::MediaPlaybackType_Music);
  ComPtr<Media::IMusicDisplayProperties> properties;
  if (SUCCEEDED(display->get_MusicProperties(properties.GetAddressOf()))) {
    properties->put_Title(HString(title).get());
    properties->put_Artist(HString(series).get());
  }
  if (const auto art = thumbnail(poster))
    display->put_Thumbnail(art.Get());
  display->Update();
}

void SmtcNative::setTimeline(double duration, double position, double rate, bool seekable) {
  auto &state = *m_state;
  if (!state.timeline)
    return;
  if (seekable && !state.seekToken) {
    EventRegistrationToken token{};
    if (SUCCEEDED(state.timeline->add_PlaybackPositionChangeRequested(state.seekHandler.Get(), &token)))
      state.seekToken = token;
  } else if (!seekable && state.seekToken) {
    state.timeline->remove_PlaybackPositionChangeRequested(*state.seekToken);
    state.seekToken.reset();
  }
  auto &properties = state.properties;
  if (!properties) {
    ComPtr<IInspectable> instance;
    const HString name(L"Windows.Media.SystemMediaTransportControlsTimelineProperties");
    if (FAILED(RoActivateInstance(name.get(), instance.GetAddressOf())) || FAILED(instance.As(&properties)))
      return;
  }
  duration = std::isfinite(duration) ? std::max(0.0, duration) : 0.0;
  position = std::isfinite(position) ? std::clamp(position, 0.0, duration) : 0.0;
  properties->put_StartTime({0});
  properties->put_EndTime(timeSpan(duration));
  properties->put_MinSeekTime({0});
  properties->put_MaxSeekTime(timeSpan(seekable ? duration : 0));
  properties->put_Position(timeSpan(position));
  state.timeline->put_PlaybackRate(rate);
  state.timeline->UpdateTimelineProperties(properties.Get());
}
