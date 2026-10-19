package com.thumble.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider

/** Application-context resources only: a recreated screen never owns or abandons a socket. */
internal class ControllerSession(store: SessionStore, discovery: MacDiscovery) : ViewModel() {
    var state by mutableStateOf(ClientState())
        private set
    val client = ControllerClient(store, discovery) { state = it }
    override fun onCleared() { client.dispose() }

    class Factory(private val context: Context) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass == ControllerSession::class.java)
            return modelClass.cast(ControllerSession(ClientDependencies.sessionStore(context), NsdMacDiscovery(context)))!!
        }
    }
}
