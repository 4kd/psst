module Update exposing (update)

import Animation
import Dom.Scroll exposing (toBottom)
import Element
import Json exposing (decodeScrollEvent, decodeSocketText, encodeDataTransmit, encodePublicKey)
import Json.Decode
import Json.Encode
import Navigation exposing (newUrl)
import Ports
import Task
import Types exposing (ConnId(..), Model, Msg(..), PublicKeyString(..), SocketMessages(..), ScrollStatus(..), TypingStatus(..), Status(..))
import WebSocket


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        StartMsg ->
            model ! [ start model.wsApi ]

        CbScrollToBottom _ ->
            { model | arrow = False } ! []

        InputChange str ->
            let
                ( pinged, cmd ) =
                    if (model.lastTyped - model.lastTypedPing) > 4000 then
                        case model.status of
                            Ready connId _ ->
                                ( model.time
                                , Json.Encode.string "TYPING"
                                    |> encodeDataTransmit connId
                                    |> WebSocket.send model.wsApi
                                )

                            _ ->
                                ( model.lastTypedPing, Cmd.none )
                    else
                        ( model.lastTypedPing, Cmd.none )
            in
                { model | input = str, lastTyped = model.time, lastTypedPing = pinged } ! [ cmd ]

        Send ->
            if String.isEmpty model.input then
                model ! []
            else
                case model.status of
                    Ready _ _ ->
                        { model
                            | input = ""
                            , messages = model.messages ++ [ { self = True, content = model.input } ]
                        }
                            ! [ Ports.encrypt model.input, scrollToBottom ]

                    a ->
                        model ! [ log "send, oops" a ]

        Resize size ->
            { model | device = Element.classifyDevice size } ! []

        CbEncrypt txt ->
            case model.status of
                Ready connId _ ->
                    let
                        messageTransfer =
                            [ ( "message", Json.Encode.string txt )
                            ]
                                |> Json.Encode.object
                                |> encodeDataTransmit connId
                                |> WebSocket.send model.wsApi
                    in
                        model
                            ! [ messageTransfer ]

                a ->
                    model ! [ log "cbEncrypt, oops" a ]

        CbDecrypt txt ->
            case model.status of
                Ready connId _ ->
                    { model
                        | messages = model.messages ++ [ { self = False, content = txt } ]
                        , status = Ready connId NotTyping
                    }
                        ! [ scrollToBottom ]

                _ ->
                    model ! []

        Animate animMsg ->
            { model
                | keySpin = Animation.update animMsg model.keySpin
            }
                ! []

        Tick time ->
            { model | time = time } ! []

        ScrollToBottom ->
            model ! [ scrollToBottom ]

        PublicKeyLoaded () ->
            case model.status of
                WaitingForBKey _ connId _ ->
                    { model | status = Ready connId NotTyping } ! [ newUrl "/" ]

                WaitingForAKey connId ->
                    { model | status = Ready connId NotTyping } ! [ newUrl "/" ]

                _ ->
                    model ! []

        DisplayScrollButton event ->
            case model.scroll of
                Static ->
                    let
                        ( h, arrow ) =
                            isBottom event
                    in
                        { model | arrow = not arrow, scroll = Moving model.time h } ! []

                Moving pre h ->
                    if (model.time - pre) > 50 then
                        let
                            ( newH, arrow ) =
                                isBottom event

                            scroll =
                                if h == newH then
                                    Static
                                else
                                    Moving model.time newH
                        in
                            { model | arrow = not arrow, scroll = scroll } ! []
                    else
                        model ! []

        CbWebsocketMessage str ->
            case Json.Decode.decodeString decodeSocketText str of
                Ok socketMsg ->
                    case socketMsg of
                        Waiting bId room ->
                            case model.status of
                                Start pk ->
                                    { model | status = WaitingForBKey pk bId room } ! []

                                a ->
                                    model ! [ log "waiting, oops" a ]

                        ReceiveMessage txt ->
                            model ! [ Ports.decrypt txt ]

                        Typing ->
                            case model.status of
                                Ready connId _ ->
                                    { model | status = Ready connId (IsTyping model.time) } ! []

                                _ ->
                                    model ! []

                        Error err ->
                            model ! [ log "socket server error" err ]

                        RoomUnavailable ->
                            case model.status of
                                Joining myPublicKey ->
                                    { model
                                        | status = Start myPublicKey
                                        , keySpin =
                                            Animation.interrupt
                                                [ Animation.set [ Animation.rotate (Animation.deg 0) ]
                                                ]
                                                model.keySpin
                                    }
                                        ! [ log "room unavailable" 0, newUrl "/" ]

                                a ->
                                    model ! [ log "room unavailable, oops" a ]

                        ReceiveAId connId ->
                            case model.status of
                                Joining myPublicKey ->
                                    let
                                        keyTransfer =
                                            [ ( "key", encodePublicKey myPublicKey )
                                            ]
                                                |> Json.Encode.object
                                                |> encodeDataTransmit connId
                                                |> WebSocket.send model.wsApi
                                    in
                                        { model | status = WaitingForAKey connId }
                                            ! [ keyTransfer ]

                                a ->
                                    model ! [ log "start, oops" a ]

                        Key theirPublicKey ->
                            case model.status of
                                WaitingForBKey myPublicKey connId _ ->
                                    let
                                        keyTransfer =
                                            [ ( "key", encodePublicKey myPublicKey )
                                            ]
                                                |> Json.Encode.object
                                                |> encodeDataTransmit connId
                                                |> WebSocket.send model.wsApi
                                    in
                                        model
                                            ! [ keyTransfer
                                              , Ports.loadPublicKey <| encodePublicKey theirPublicKey
                                              ]

                                WaitingForAKey _ ->
                                    let
                                        keySpin =
                                            Animation.interrupt
                                                [ Animation.set [ Animation.rotate (Animation.deg 0) ]
                                                ]
                                                model.keySpin
                                    in
                                        { model
                                            | keySpin = keySpin
                                        }
                                            ! [ Ports.loadPublicKey <| encodePublicKey theirPublicKey
                                              ]

                                a ->
                                    model ! [ log "key swap, oops" a ]

                Err err ->
                    model ! [ log "socket message error" err ]


start : String -> Cmd Msg
start wsUrl =
    Json.Encode.string "START"
        |> Json.Encode.encode 0
        |> WebSocket.send wsUrl


isBottom : Json.Decode.Value -> ( number, Bool )
isBottom =
    Json.Decode.decodeValue decodeScrollEvent
        >> Result.map
            (\{ scrollHeight, scrollTop, clientHeight } ->
                -- https://gist.github.com/paulirish/5d52fb081b3570c81e3a
                ( scrollTop, (scrollHeight - scrollTop) < (clientHeight + 100) )
            )
        >> Result.withDefault ( 99, False )


scrollToBottom : Cmd Msg
scrollToBottom =
    toBottom "messages"
        |> Task.attempt CbScrollToBottom


log : String -> a -> Cmd Msg
log tag a =
    let
        _ =
            Debug.log tag a
    in
        Cmd.none