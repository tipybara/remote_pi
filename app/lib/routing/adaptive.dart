import 'package:app/data/transport/epk_encoding.dart';
import 'package:flutter/widgets.dart';

/// Lado menor (em pixels lógicos) a partir do qual o app entra no modo tablet
/// de dois painéis (master + detail).
const double kTabletBreakpoint = 600.0;

/// `true` quando a janela é "classe tablet" — larga o bastante, em qualquer
/// orientação, para o layout de dois painéis.
///
/// Classificamos por `shortestSide` (= `min(width, height)`), **não** por
/// `width`, porque a largura sozinha confunde classe-de-device com orientação:
/// um CELULAR em landscape tem `width >= 600` e virava "tablet" por engano (o
/// bug que isto corrige). `shortestSide` é invariante à rotação:
///   • Celular: shortestSide ~360–430 (< 600) em qualquer orientação → phone.
///   • Tablet:  shortestSide >= 768 em qualquer orientação → tablet.
///
/// Split View / Slide Over do iPadOS continua colapsando pra painel único: o
/// `MediaQuery` mede a JANELA dada ao app, não o device físico. Quando o usuário
/// encolhe o app numa coluna estreita, `shortestSide` cai junto abaixo de 600 e
/// voltamos a phone. Ou seja, `shortestSide` atende os dois objetivos de uma vez
/// — estável como classe-de-device E sensível a multitarefa estreita.
///
/// É estritamente mais rígido que `width` (exige AMBAS as dimensões >= 600). A
/// única diferença de comportamento vs. o critério antigo é justamente
/// "landscape com altura < 600" (= celulares) passar a ser phone — o desejado.
bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= kTabletBreakpoint;

/// Largura máxima de conteúdo de coluna única (onboarding, empty states).
/// Acima disso o conteúdo é centralizado em vez de esticar borda-a-borda —
/// evita o efeito "UI de celular gigante" no tablet.
const double kMaxContentWidth = 460.0;

/// Centraliza e limita a largura do [child] em telas largas; em larguras de
/// celular é praticamente um passthrough (o conteúdo já preenche a tela).
/// Centraliza nos dois eixos, então serve tanto para conteúdo de altura
/// mínima (empty states) quanto para colunas full-height (onboarding com
/// `Expanded`).
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = kMaxContentWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Estado de layout do shell adaptativo. Hoje carrega só `isZeroState`:
/// `true` quando a Home não tem nada para listar/selecionar (sem Pi pareado
/// ou lista vazia). Nesse caso o shell colapsa para um único painel cheio e
/// centralizado, em vez de mostrar o split com um placeholder grande e vazio.
///
/// Default `false` (split por padrão em telas largas) para não piscar
/// single→split no caso comum de já existirem sessões no boot.
class ShellLayout extends ChangeNotifier {
  bool _zeroState = false;
  bool get isZeroState => _zeroState;

  void setZeroState(bool value) {
    if (value == _zeroState) return;
    _zeroState = value;
    notifyListeners();
  }
}

/// Sessão atualmente selecionada na UI (o chat mostrado no painel detail
/// do tablet e destacado na lista master).
///
/// É **distinta** do peer conectado (`Preferences.selectedPeerEpk`, setado
/// no boot): começa `null` de propósito para que, ao abrir o app, nenhum
/// chat apareça pré-selecionado — o placeholder é mostrado até o primeiro
/// toque. Vive enquanto o app roda (não é restaurada entre execuções, já
/// que queremos iniciar sempre sem seleção).
class SessionSelection extends ChangeNotifier {
  ({String epk, String roomId, String title, String device, bool online})?
  _current;

  ({String epk, String roomId, String title, String device, bool online})?
  get current => _current;

  /// Plan-61 Fase 0 — chave estável da seleção: `<epk-normalizado>|<roomId>`.
  /// `null` quando nada está selecionado. Usada como `ValueKey` do painel
  /// detail no tablet.
  String? get sessionKey {
    final c = _current;
    return c == null ? null : '${toStandardB64(c.epk)}|${c.roomId}';
  }

  /// `true` se `(epk, roomId)` é a sessão selecionada agora.
  ///
  /// Plan-61 Fase 0 — compara o epk **normalizado**. O mesmo Pi chega aqui
  /// ora em base64url (`PeerRecord.remoteEpk`, vindo do QR/storage) ora em
  /// base64 padrão (o que o relay reporta). Comparando as strings cruas, a
  /// mesma sessão deixava de casar consigo mesma e o tile perdia o
  /// destaque / o detail-pane não reconhecia a seleção. Ver
  /// `epk_encoding.dart` para o histórico recorrente desse bug.
  bool matches(String epk, String roomId) {
    final c = _current;
    return c != null &&
        toStandardB64(c.epk) == toStandardB64(epk) &&
        c.roomId == roomId;
  }

  /// Plan/32g — `device` é o nome do dispositivo pareado (nickname /
  /// sessionName) que o Home já conhece; o detail-pane do tablet o repassa pro
  /// `ChatPage.initialDevice` pra renderizar a linha 2 da AppBar de cara, sem
  /// esperar o PeerRecord assíncrono. `online` é o estado live do tile (verde),
  /// repassado pro `ChatPage.initialOnline` pra o ponto de status não piscar
  /// "reconnecting" no boot do runtime. Ambos opcionais pra não quebrar
  /// chamadas legadas/testes que só passam o título.
  void select(
    String epk,
    String roomId,
    String title, [
    String device = '',
    bool online = false,
  ]) {
    final c = _current;
    if (c != null &&
        toStandardB64(c.epk) == toStandardB64(epk) &&
        c.roomId == roomId) {
      return; // no-op — evita rebuild do detail/master
    }
    _current = (
      epk: epk,
      roomId: roomId,
      title: title,
      device: device,
      online: online,
    );
    notifyListeners();
  }

  void clear() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }
}
